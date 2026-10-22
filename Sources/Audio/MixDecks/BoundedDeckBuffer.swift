#if !os(watchOS)
import Foundation
import Synchronization

/// A run of decoded source frames for one deck, tagged with the generation it was requested under.
struct DeckChunk: Sendable {
    let generation: Int
    let startFrame: Int64
    /// Planar samples, one array per channel, all the same length.
    let channels: [[Float]]
    var frameCount: Int { channels.first?.count ?? 0 }
}

enum DeckChunkWriteResult: Equatable, Sendable {
    case accepted(Int)
    /// The deck was seeked or retargeted after this chunk was requested.
    case stale
    case discontinuous(expected: Int64)
    case full
    case finished
}

/// Where a deck's decoded audio comes from (a file decoder in production). Reads may return fewer
/// frames than asked; an empty result is a stall (disk, network), never end of media.
protocol DeckChunkSource: Sendable {
    func read(startFrame: Int64, count: Int) throws -> [[Float]]
}

/// Fixed-size decode-ahead buffer for one Smart Blend deck: the replacement for whole-track
/// resident PCM. Holds only source frames `[readFrame, writeFrame)`; its memory is set at init
/// and never grows with the track's length.
///
/// Threading contract (single producer, single consumer): the producer (a decode task) calls
/// `nextRequest`/`write`/`refill`; the consumer (the render callback) calls `render`; the
/// controller calls `retarget`. `render` does no I/O, allocation, locking or object destruction:
/// it touches only preallocated storage and atomics. The `@unchecked Sendable` is sound because
/// every cross-thread value is an `Atomic`, and each plain `var` (`fraction`) is consumer-only.
final class BoundedDeckBuffer: @unchecked Sendable {
    static let generationBits: UInt64 = 24
    private static let frameBits: UInt64 = 40
    private static let frameMask: UInt64 = (1 << frameBits) - 1
    private static let generationMask: Int = (1 << Int(generationBits)) - 1

    let capacityFrames: Int
    let channelCount: Int
    var residentBytes: Int { capacityFrames * channelCount * MemoryLayout<Float>.size }

    private let storage: UnsafeMutablePointer<Float>
    /// generation << 40 | start frame: one atomic so a reader never pairs a new generation with an old target.
    private let request = Atomic<UInt64>(0)
    private let total = Atomic<Int64>(0)
    private let writeFrameStore = Atomic<Int64>(0)
    private let writeGeneration = Atomic<Int>(-1)
    private let readFrameStore = Atomic<Int64>(0)
    private let readGeneration = Atomic<Int>(-1)
    private let underruns = Atomic<Int>(0)
    /// Consumer-only: fractional source offset past `readFrame` (non-unit tempo).
    private var fraction = 0.0

    init(capacityFrames: Int, channelCount: Int = 2) {
        precondition(capacityFrames > 0 && channelCount > 0)
        self.capacityFrames = capacityFrames
        self.channelCount = channelCount
        storage = .allocate(capacity: capacityFrames * channelCount)
        storage.initialize(repeating: 0, count: capacityFrames * channelCount)
    }

    deinit { storage.deallocate() }

    // MARK: Controller

    private static func pack(generation: Int, frame: Int64) -> UInt64 {
        (UInt64(generation & generationMask) << frameBits) | (UInt64(max(0, frame)) & frameMask)
    }

    private static func unpack(_ value: UInt64) -> (generation: Int, frame: Int64) {
        (Int(value >> frameBits), Int64(value & frameMask))
    }

    /// Current generation. Chunks requested under an earlier one are refused.
    var generation: Int { Self.unpack(request.load(ordering: .acquiring)).generation }
    var totalFrames: Int64 { total.load(ordering: .acquiring) }

    /// Points the deck at (possibly another) track and a source frame. Invalidates every chunk in
    /// flight, so a cancelled decode can never refill a reused deck. Controller thread only.
    @discardableResult
    func retarget(totalFrames: Int64, startFrame: Int64) -> Int {
        total.store(max(0, totalFrames), ordering: .releasing)
        let next = (generation + 1) & Self.generationMask
        request.store(Self.pack(generation: next, frame: min(max(0, startFrame), max(0, totalFrames))),
                      ordering: .releasing)
        return next
    }

    func seek(to frame: Int64) { retarget(totalFrames: totalFrames, startFrame: frame) }

    // MARK: Producer

    /// Applies a pending retarget to the write side and returns the current request.
    private func syncProducer() -> (generation: Int, frame: Int64) {
        let req = Self.unpack(request.load(ordering: .acquiring))
        if writeGeneration.load(ordering: .acquiring) != req.generation {
            writeFrameStore.store(req.frame, ordering: .releasing)
            writeGeneration.store(req.generation, ordering: .releasing)
        }
        return req
    }

    /// What to decode next: the generation to tag it with, where it starts, and how many frames fit.
    func nextRequest() -> (generation: Int, startFrame: Int64, wanted: Int) {
        let req = syncProducer()
        let write = writeFrameStore.load(ordering: .acquiring)
        // A consumer that has not yet applied this generation will start reading at the target.
        let read = readGeneration.load(ordering: .acquiring) == req.generation
            ? readFrameStore.load(ordering: .acquiring) : req.frame
        let free = capacityFrames - Int(write - read)
        let remaining = max(0, totalFrames - write)
        return (req.generation, write, Int(min(Int64(max(0, free)), remaining)))
    }

    func write(_ chunk: DeckChunk) -> DeckChunkWriteResult {
        let req = syncProducer()
        guard chunk.generation & Self.generationMask == req.generation else { return .stale }
        let write = writeFrameStore.load(ordering: .acquiring)
        guard chunk.startFrame == write else { return .discontinuous(expected: write) }
        guard chunk.channels.count == channelCount else { return .discontinuous(expected: write) }
        let remaining = totalFrames - write
        guard remaining > 0 else { return .finished }
        // A consumer that has not yet applied this generation will start reading at the target.
        let read = readGeneration.load(ordering: .acquiring) == req.generation
            ? readFrameStore.load(ordering: .acquiring) : req.frame
        let free = capacityFrames - Int(write - read)
        let count = min(chunk.frameCount, free, Int(min(remaining, Int64(Int.max))))
        guard count > 0 else { return .full }
        for channel in 0..<channelCount {
            let base = storage + channel * capacityFrames
            chunk.channels[channel].withUnsafeBufferPointer { src in
                for i in 0..<count { base[Int((write + Int64(i)) % Int64(capacityFrames))] = src[i] }
            }
        }
        writeFrameStore.store(write + Int64(count), ordering: .releasing)
        return .accepted(count)
    }

    /// Decodes ahead until the buffer is full, the source stalls or the deck is retargeted.
    /// Returns the frames added. Never asks the source for more than fits, so memory stays bounded.
    @discardableResult
    func refill(from source: some DeckChunkSource, maxChunkFrames: Int = 8_192) throws -> Int {
        var added = 0
        while true {
            let request = nextRequest()
            guard request.wanted > 0 else { break }
            let channels = try source.read(startFrame: request.startFrame, count: min(request.wanted, maxChunkFrames))
            guard (channels.first?.isEmpty ?? true) == false else { break }   // stalled: try again later
            let result = write(DeckChunk(generation: request.generation, startFrame: request.startFrame,
                                         channels: channels))
            guard case .accepted(let n) = result else { break }
            added += n
        }
        return added
    }

    // MARK: Consumer

    struct RenderOutcome: Equatable, Sendable {
        var delivered: Int
        /// Frames asked for but not available: filled with silence, counted, never skipped over.
        var underran: Bool
        var finished: Bool
    }

    /// Source frame the next output sample comes from.
    var positionFrame: Int64 { readFrameStore.load(ordering: .acquiring) }

    /// Like `positionFrame`, but a retarget (seek, new track) counts at once instead of when the
    /// render callback next applies it: where this deck plays from *now*, as far as the controller cares.
    var currentFrame: Int64 {
        let req = Self.unpack(request.load(ordering: .acquiring))
        return readGeneration.load(ordering: .acquiring) == req.generation
            ? readFrameStore.load(ordering: .acquiring) : req.frame
    }
    var underrunCount: Int { underruns.load(ordering: .relaxed) }

    /// Decoded frames ahead of the read position under the current generation.
    var bufferedFrames: Int {
        let gen = generation
        guard writeGeneration.load(ordering: .acquiring) == gen else { return 0 }
        let read = readGeneration.load(ordering: .acquiring) == gen
            ? readFrameStore.load(ordering: .acquiring) : Self.unpack(request.load(ordering: .acquiring)).frame
        return max(0, Int(writeFrameStore.load(ordering: .acquiring) - read))
    }

    /// Writes `frames` planar frames (channel stride `stride`) at `tempo` source frames per output
    /// frame. A position is only consumed once `prerollFrames` of lookahead beyond it is buffered
    /// (what a keylock resampler needs to prime), unless the end of the source is buffered.
    /// Real-time safe.
    func render(into out: UnsafeMutablePointer<Float>, stride: Int, frames: Int, tempo: Double,
                prerollFrames: Int = 0) -> RenderOutcome {
        let req = Self.unpack(request.load(ordering: .acquiring))
        if readGeneration.load(ordering: .acquiring) != req.generation {
            readFrameStore.store(req.frame, ordering: .releasing)
            fraction = 0
            readGeneration.store(req.generation, ordering: .releasing)
        }
        for channel in 0..<channelCount { (out + channel * stride).update(repeating: 0, count: frames) }
        guard writeGeneration.load(ordering: .acquiring) == req.generation else {
            underruns.wrappingAdd(1, ordering: .relaxed)
            return RenderOutcome(delivered: 0, underran: true, finished: false)
        }
        let write = writeFrameStore.load(ordering: .acquiring)
        let end = total.load(ordering: .acquiring)
        var read = readFrameStore.load(ordering: .relaxed)
        let atEnd = write >= end
        var delivered = 0
        while delivered < frames {
            if read >= end { break }
            let needsNext = fraction > 0
            let lastNeeded = read + Int64(preroll(prerollFrames, needsNext))
            if lastNeeded >= write && !atEnd { break }
            if read >= write { break }
            for channel in 0..<channelCount {
                let base = storage + channel * capacityFrames
                let a = base[Int(read % Int64(capacityFrames))]
                var sample = a
                if needsNext {
                    let nextFrame = min(read + 1, end - 1)
                    let b = nextFrame < write ? base[Int(nextFrame % Int64(capacityFrames))] : a
                    sample = a + (b - a) * Float(fraction)
                }
                out[channel * stride + delivered] = sample
            }
            delivered += 1
            fraction += tempo
            let whole = Int64(fraction)
            read += whole
            fraction -= Double(whole)
        }
        readFrameStore.store(read, ordering: .releasing)
        let finished = read >= end
        let underran = delivered < frames && !finished
        if underran { underruns.wrappingAdd(1, ordering: .relaxed) }
        return RenderOutcome(delivered: delivered, underran: underran, finished: finished)
    }

    private func preroll(_ preroll: Int, _ needsNext: Bool) -> Int { preroll + (needsNext ? 1 : 0) }
}
#endif
