#if !os(watchOS)
import Foundation

/// Why the shared sample clock is frozen.
enum BoundedDeckPauseReason: String, Sendable, Equatable {
    case user, routeChange, interruption, backgrounded
}

enum BoundedDeckPhase: Equatable, Sendable {
    case idle
    /// The current deck has no audio buffered yet (start, seek, or a disk stall).
    case filling
    case playing
    /// The planned overlap time has come but the incoming deck is not buffered enough: the
    /// outgoing deck keeps playing alone and no fade has started.
    case waitingForIncoming
    case overlapping
    case paused(BoundedDeckPauseReason)
}

/// The actual state of the bounded path, published for the Smart Blend Now Playing / Queue UI.
struct BoundedDeckSnapshot: Equatable, Sendable {
    struct Deck: Equatable, Sendable {
        var bufferedSeconds: Double
        var positionSeconds: Double
        var generation: Int
        var underruns: Int
    }
    var phase: BoundedDeckPhase
    var clockFrame: Int64
    var current: Deck
    var incoming: Deck
    /// Fixed for the session: both decks' buffers, whatever the media length.
    var residentBytes: Int
    var stalledFrames: Int64
    var clippedSamples: Int
}

/// How the two decks share the overlap.
enum BoundedOverlapStyle: Equatable, Sendable {
    /// Equal-power crossfade of the full signal.
    case crossfade
    /// Highs crossfade across the overlap; the low band (below `BoundedDeckMixer.crossoverHz`)
    /// moves from the outgoing to the incoming deck at `swapOffsetFrames`.
    case bassSwap
    /// Both decks full range: the incoming builds in until `swapOffsetFrames`, where its bass takes
    /// over and the outgoing then leaves.
    case doubleDrop
}

struct BoundedOverlapPlan: Equatable, Sendable {
    /// Shared-clock frame at which the incoming deck should become audible. Ignored when
    /// `outgoingTriggerFrame` is set.
    var startClock: Int64
    /// When set, the overlap starts when the outgoing deck's source position reaches this frame
    /// (so a plan stated in the outgoing track's own time is exact whatever its tempo history).
    var outgoingTriggerFrame: Int64? = nil
    var style: BoundedOverlapStyle = .crossfade
    /// Frames into the overlap at which the bass swaps (`bassSwap`/`doubleDrop`).
    var swapOffsetFrames: Int = 0
    var fadeFrames: Int
    var incomingStartFrame: Int64
    var incomingTotalFrames: Int64
    var incomingTempo: Double = 1
    var incomingGain: Float = 1
    /// Decoded audio the incoming deck must have buffered before the fade may begin.
    var minIncomingBufferedFrames: Int
}

/// Two bounded decks on one shared sample clock. The render path allocates nothing (scratch is
/// preallocated), does no I/O and takes no locks. The overlap is committed only once the incoming
/// deck holds `minIncomingBufferedFrames`, so a stalled disk delays the fade instead of starting it
/// over silence. Control calls and `render` must be serialized by the caller (offline: one thread;
/// live: a single audio-thread mailbox).
final class BoundedDeckMixer {
    enum Overlap: Equatable {
        case none
        case pending(BoundedOverlapPlan)
        case active(plan: BoundedOverlapPlan, fadeStart: Int64)
    }

    let sampleRate: Double
    let decks: [BoundedDeckBuffer]
    let maxBlockFrames: Int
    let prerollFrames: Int
    private let channelCount: Int
    private let scratch: UnsafeMutablePointer<Float>
    /// Where the low band is split for a bass swap.
    static let crossoverHz = 150.0
    /// After a handoff the new current deck eases back to native tempo over this many seconds.
    static let tempoEaseSeconds = 4.0
    private var tempos = [1.0, 1.0]
    /// The deck that has just taken over from a blend and is returning to native tempo.
    private var easing = [false, false]
    /// [deck][channel][stage 0..3][z1, z2]: a Linkwitz-Riley (4th order) crossover per deck and channel;
    /// stages 0-1 are the low-pass, 2-3 the high-pass (flat sum, ~24 dB/oct, so a bass swap does not leak).
    private var filterState: UnsafeMutablePointer<Float>
    private let lowPass: (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float)
    private let highPass: (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float)
    private var stateStride: Int { channelCount * 8 }
    private var gains: [Float] = [1, 1]
    private(set) var clock: Int64 = 0
    private(set) var main = 0
    private(set) var overlap = Overlap.none
    private(set) var pauseReason: BoundedDeckPauseReason?
    private(set) var stalledFrames: Int64 = 0
    private(set) var clippedSamples = 0
    private var waiting = false

    var incomingIndex: Int { 1 - main }

    init(sampleRate: Double = 44_100, capacityFrames: Int, channelCount: Int = 2,
         maxBlockFrames: Int = 4_096, prerollFrames: Int = 0) {
        self.sampleRate = sampleRate
        self.maxBlockFrames = maxBlockFrames
        self.prerollFrames = prerollFrames
        self.channelCount = channelCount
        decks = [BoundedDeckBuffer(capacityFrames: capacityFrames, channelCount: channelCount),
                 BoundedDeckBuffer(capacityFrames: capacityFrames, channelCount: channelCount)]
        scratch = .allocate(capacity: 2 * channelCount * maxBlockFrames)
        scratch.initialize(repeating: 0, count: 2 * channelCount * maxBlockFrames)
        filterState = .allocate(capacity: 2 * channelCount * 8)
        filterState.initialize(repeating: 0, count: 2 * channelCount * 8)
        // RBJ biquads, Butterworth Q: two cascaded make each side Linkwitz-Riley.
        let w0 = 2 * Double.pi * Self.crossoverHz / sampleRate
        let alpha = sin(w0) / (2 * 0.7071067811865476), c = cos(w0), a0 = 1 + alpha
        let a1 = Float(-2 * c / a0), a2 = Float((1 - alpha) / a0)
        lowPass = (Float((1 - c) / 2 / a0), Float((1 - c) / a0), Float((1 - c) / 2 / a0), a1, a2)
        highPass = (Float((1 + c) / 2 / a0), Float(-(1 + c) / a0), Float((1 + c) / 2 / a0), a1, a2)
    }

    deinit { scratch.deallocate(); filterState.deallocate() }

    /// One transposed direct-form II biquad step on `z` (two floats of state).
    @inline(__always)
    private func biquad(_ c: (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float),
                        _ z: UnsafeMutablePointer<Float>, _ x: Float) -> Float {
        let y = c.b0 * x + z[0]
        z[0] = c.b1 * x - c.a1 * y + z[1]
        z[1] = c.b2 * x - c.a2 * y
        return y
    }

    /// Splits `x` for `deck`/`channel` into (low, high).
    @inline(__always)
    private func bands(deck: Int, channel: Int, _ x: Float) -> (low: Float, high: Float) {
        let z = filterState + deck * stateStride + channel * 8
        let low = biquad(lowPass, z + 2, biquad(lowPass, z, x))
        let high = biquad(highPass, z + 6, biquad(highPass, z + 4, x))
        return (low, high)
    }

    // MARK: Control

    /// Starts the current track on the main deck.
    func begin(totalFrames: Int64, startFrame: Int64, tempo: Double = 1) {
        overlap = .none
        waiting = false
        easing = [false, false]
        tempos[main] = tempo
        gains[main] = 1
        decks[main].retarget(totalFrames: totalFrames, startFrame: startFrame)
    }

    /// Seeks the current track; any overlap is cancelled and the incoming deck's chunks invalidated.
    func seek(to frame: Int64) {
        cancelOverlap()
        decks[main].seek(to: frame)
    }

    func schedule(_ plan: BoundedOverlapPlan) {
        decks[incomingIndex].retarget(totalFrames: plan.incomingTotalFrames, startFrame: plan.incomingStartFrame)
        tempos[incomingIndex] = plan.incomingTempo
        gains[incomingIndex] = plan.incomingGain
        easing[incomingIndex] = false
        overlap = .pending(plan)
    }

    /// Drops a pending or active overlap. The incoming deck is retargeted to nothing so a decode
    /// still running for it can no longer write.
    func cancelOverlap() {
        guard overlap != .none else { return }
        overlap = .none
        waiting = false
        decks[incomingIndex].retarget(totalFrames: 0, startFrame: 0)
    }

    func pause(_ reason: BoundedDeckPauseReason) { pauseReason = reason }
    func resume() { pauseReason = nil }

    // MARK: Render

    /// Mixes `frames` planar frames (channel stride `frames`) into `out`. Real-time safe.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        precondition(frames <= maxBlockFrames)
        for channel in 0..<channelCount { (out + channel * frames).update(repeating: 0, count: frames) }
        guard pauseReason == nil else { return }       // both decks and the timeline stay frozen
        var done = 0
        while done < frames {
            var n = frames - done
            if case .pending(let plan) = overlap {
                let due: Bool
                if let trigger = plan.outgoingTriggerFrame {
                    let position = decks[main].positionFrame
                    due = position >= trigger
                    if !due {                       // never step past the trigger inside one segment
                        let ahead = Double(trigger - position) / max(tempos[main], 0.01)
                        if ahead < Double(n) { n = max(1, Int(ahead.rounded(.up))) }
                    }
                } else {
                    due = clock >= plan.startClock
                    if !due, plan.startClock - clock < Int64(n) { n = Int(plan.startClock - clock) }
                }
                if due {
                    if decks[incomingIndex].bufferedFrames >= max(plan.minIncomingBufferedFrames, prerollFrames + 1) {
                        overlap = .active(plan: plan, fadeStart: clock)
                        filterState.update(repeating: 0, count: 2 * stateStride)
                        waiting = false
                    } else {
                        waiting = true
                        stalledFrames += Int64(n)
                    }
                }
            }
            renderSegment(out: out + done, outStride: frames, frames: n)
            done += n
            clock += Int64(n)
        }
    }

    private func renderSegment(out: UnsafeMutablePointer<Float>, outStride: Int, frames n: Int) {
        let stride = maxBlockFrames
        let a = scratch
        let b = scratch + channelCount * stride
        _ = decks[main].render(into: a, stride: stride, frames: n, tempo: tempos[main], prerollFrames: prerollFrames)
        var fade: (plan: BoundedOverlapPlan, start: Int64)?
        if case .active(let plan, let start) = overlap {
            fade = (plan, start)
            _ = decks[incomingIndex].render(into: b, stride: stride, frames: n, tempo: tempos[incomingIndex],
                                            prerollFrames: prerollFrames)
        }
        let mainGain = gains[main], incomingGain = gains[incomingIndex]
        for i in 0..<n {
            var highOut: Float = 1, highIn: Float = 0, lowOut: Float = 1, lowIn: Float = 0
            var split = false
            if let fade {
                let plan = fade.plan
                let elapsed = Double(clock + Int64(i) - fade.start)
                let t = min(max(elapsed / Double(max(1, plan.fadeFrames)), 0), 1)
                switch plan.style {
                case .crossfade:
                    highOut = Float(cos(t * .pi / 2)); highIn = Float(sin(t * .pi / 2))
                    lowOut = highOut; lowIn = highIn
                case .bassSwap, .doubleDrop:
                    split = true
                    let ts = min(max(Double(plan.swapOffsetFrames) / Double(max(1, plan.fadeFrames)), 0.001), 0.999)
                    if plan.style == .bassSwap {
                        highOut = Float(cos(t * .pi / 2)); highIn = Float(sin(t * .pi / 2))
                    } else if t < ts {
                        highOut = 1; highIn = Float(sin(t / ts * .pi / 2))
                    } else {
                        highOut = Float(cos((t - ts) / (1 - ts) * .pi / 2)); highIn = 1
                    }
                    // The low band changes hands inside a ~10 ms window around the swap (no click).
                    let ramp = max(1.0, 0.010 * sampleRate)
                    let u = min(max((elapsed - Double(plan.swapOffsetFrames)) / ramp + 0.5, 0), 1)
                    lowIn = Float(u); lowOut = Float(1 - u)
                }
            }
            for channel in 0..<channelCount {
                var sample: Float
                let x = a[channel * stride + i]
                if fade == nil {
                    sample = x * mainGain
                } else {
                    let y = b[channel * stride + i]
                    if split {
                        let bandsOut = bands(deck: main, channel: channel, x)
                        let bandsIn = bands(deck: incomingIndex, channel: channel, y)
                        sample = (bandsOut.high * highOut + bandsOut.low * lowOut) * mainGain
                            + (bandsIn.high * highIn + bandsIn.low * lowIn) * incomingGain
                    } else {
                        sample = x * highOut * mainGain + y * highIn * incomingGain
                    }
                }
                if sample > 1 || sample < -1 { clippedSamples += 1; sample = min(max(sample, -1), 1) }
                out[channel * outStride + i] = sample
            }
        }
        if let fade, clock + Int64(n) >= fade.start + Int64(fade.plan.fadeFrames) {
            main = incomingIndex                       // the incoming deck is now the current track
            gains[main] = fade.plan.incomingGain
            overlap = .none
            easing[main] = true
            handoffs += 1
        }
        easeTempo(of: main, frames: n)
    }

    /// Number of completed handoffs (a monotonic counter the controller polls).
    private(set) var handoffs = 0

    /// A track that entered a blend at the plan's tempo returns to native speed gradually after the
    /// handoff, so the next plan (stated in native time) meets it at 1.0 without a pitch step.
    private func easeTempo(of deck: Int, frames n: Int) {
        guard easing[deck] else { return }
        if case .active = overlap { return }
        guard abs(tempos[deck] - 1) > 1e-4 else { tempos[deck] = 1; easing[deck] = false; return }
        let step = Double(n) / (Self.tempoEaseSeconds * sampleRate)
        tempos[deck] += (1 - tempos[deck]) * min(1, step * 4)
    }

    /// Offline convenience for tests: renders and returns planar channels. Allocates.
    func renderOffline(frames: Int) -> [[Float]] {
        var result = [[Float]](repeating: [], count: channelCount)
        var block = [Float](repeating: 0, count: channelCount * maxBlockFrames)
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, maxBlockFrames)
            block.withUnsafeMutableBufferPointer { render(into: $0.baseAddress!, frames: n) }
            for channel in 0..<channelCount { result[channel] += block[(channel * n)..<(channel * n + n)] }
            remaining -= n
        }
        return result
    }

    // MARK: State

    func snapshot() -> BoundedDeckSnapshot {
        func deck(_ i: Int) -> BoundedDeckSnapshot.Deck {
            .init(bufferedSeconds: Double(decks[i].bufferedFrames) / sampleRate,
                  positionSeconds: Double(decks[i].positionFrame) / sampleRate,
                  generation: decks[i].generation, underruns: decks[i].underrunCount)
        }
        let phase: BoundedDeckPhase
        if let pauseReason { phase = .paused(pauseReason) }
        else if case .active = overlap { phase = .overlapping }
        else if waiting { phase = .waitingForIncoming }
        else if decks[main].totalFrames == 0 { phase = .idle }
        else if decks[main].bufferedFrames == 0 { phase = .filling }
        else { phase = .playing }
        return BoundedDeckSnapshot(phase: phase, clockFrame: clock, current: deck(main), incoming: deck(incomingIndex),
                                   residentBytes: decks.reduce(0) { $0 + $1.residentBytes },
                                   stalledFrames: stalledFrames, clippedSamples: clippedSamples)
    }
}
#endif
