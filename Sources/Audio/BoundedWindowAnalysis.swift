import Foundation

/// Lazy, seekable range access to a source's PCM. An adapter over the upstream static
/// `AudioFileReader.decodeRange` implements this for seekable FLAC and AVFoundation containers.
/// There is deliberately no whole-file fallback: a source that cannot seek reports `false`.
public protocol RangeAudioSource: Sendable {
    var supportsRangeAccess: Bool { get }
    var sampleRate: Double { get }
    var channelCount: Int { get }
    var totalFrames: Int64 { get }
    /// Interleaved Float PCM for `[startFrame, startFrame + frameCount)`, clamped to the source.
    func decodeRange(startFrame: Int64, frameCount: Int) throws -> [Float]
}

public enum WindowAnalysisOutcome: String, Sendable, Equatable {
    case usableBeatPlacement, usablePhrasePlacement, insufficientConfidence
    case unsupportedRangeAccess, deferred, cancelled
}

public enum WindowSide: String, Sendable, Equatable, Codable { case entry, exit }

public struct WindowAnalysisBudget: Sendable, Equatable {
    public var windowSeconds: Double = 30
    public var maxWindowSeconds: Double = 60
    public var chunkFrames: Int = 1 << 16
    public var maxBytes: Int = 16 << 20
    public var maxDecodedFrames: Int64 = 4_000_000
    public var maxWallTime: TimeInterval = 5
    public var analysisRate: Double = 11_025
    public var minimumConfidence: Double = 0.35
    public var phraseBeats: Int = 16
    public init() {}
}

public struct WindowAnalysis: Sendable, Equatable, Codable {
    public var side: WindowSide
    /// Source-relative seconds of the analysed window.
    public var windowStart: Double
    public var windowEnd: Double
    public var bpm: Double?
    /// Source-relative time of the first beat in the window.
    public var firstBeatTime: Double?
    public var confidence: Double
    public var beatCount: Int
}

public struct BoundedAnalysisResult: Sendable, Equatable {
    public var outcome: WindowAnalysisOutcome
    public var entry: WindowAnalysis?
    public var exit: WindowAnalysis?
    /// Analysed seconds / track seconds. Always < 1 for long tracks.
    public var coverage: Double
    public var confidence: Double
    public var decodedFrames: Int64
    public var peakBytes: Int
    public var rangeRequests: [(start: Int64, count: Int)]
    /// Sparse endpoint analysis never claims interior structure.
    public var claimsFullTrackStructure: Bool { false }
    public var claimsInteriorDoubleDrop: Bool { false }

    public static func == (l: Self, r: Self) -> Bool {
        l.outcome == r.outcome && l.entry == r.entry && l.exit == r.exit && l.coverage == r.coverage
            && l.confidence == r.confidence && l.decodedFrames == r.decodedFrames
    }
}

/// Compact cacheable record; keyed by source fingerprint + algorithm version.
public struct BoundedAnalysisRecord: Sendable, Equatable, Codable {
    public var fingerprint: String
    public var algorithmVersion: Int
    public var entry: WindowAnalysis?
    public var exit: WindowAnalysis?
    public var coverage: Double
    public var confidence: Double
    public var outcomeRaw: String
}

public final class BoundedAnalysisCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: BoundedAnalysisRecord] = [:]
    public init() {}
    private func key(_ f: String, _ v: Int) -> String { "\(f)#\(v)" }
    public func record(fingerprint: String, version: Int) -> BoundedAnalysisRecord? {
        lock.withLock { store[key(fingerprint, version)] }
    }
    public func insert(_ r: BoundedAnalysisRecord) {
        lock.withLock { store[key(r.fingerprint, r.algorithmVersion)] = r }
    }
}

/// Streaming linear resampler that carries its phase and last sample across chunks, so
/// chunked output equals one-shot output in both content and sample count.
public struct StreamingResampler: Sendable {
    private let step: Double          // input frames per output frame
    private var position: Double = 0  // next output position, in input-frame coordinates (global)
    private var consumed: Int64 = 0
    private var previous: Float = 0
    private var hasPrevious = false
    public private(set) var outputCount = 0

    public init(from inRate: Double, to outRate: Double) { step = inRate / outRate }

    public mutating func process(_ input: [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 2)
        let base = consumed
        let end = base + Int64(input.count)
        while true {
            let i0 = Int64(position.rounded(.down))
            if i0 + 1 >= end { break }
            let frac = Float(position - Double(i0))
            let a: Float = i0 < base ? previous : input[Int(i0 - base)]
            let b = input[Int(i0 + 1 - base)]
            out.append(a + (b - a) * frac)
            position += step
        }
        if let last = input.last { previous = last; hasPrevious = true }
        consumed = end
        outputCount += out.count
        return out
    }
}

public struct BoundedWindowAnalyzer: Sendable {
    public static let algorithmVersion = 1
    public var budget: WindowAnalysisBudget
    public var clock: @Sendable () -> TimeInterval

    public init(budget: WindowAnalysisBudget = .init(),
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.budget = budget; self.clock = clock
    }

    public func analyze(source: RangeAudioSource, fingerprint: String, cache: BoundedAnalysisCache? = nil,
                        isCancelled: @Sendable () -> Bool = { false }) -> BoundedAnalysisResult {
        if let hit = cache?.record(fingerprint: fingerprint, version: Self.algorithmVersion),
           let outcome = WindowAnalysisOutcome(rawValue: hit.outcomeRaw) {
            return BoundedAnalysisResult(outcome: outcome, entry: hit.entry, exit: hit.exit,
                                         coverage: hit.coverage, confidence: hit.confidence,
                                         decodedFrames: 0, peakBytes: 0, rangeRequests: [])
        }
        let result = run(source: source, isCancelled: isCancelled)
        if result.outcome != .cancelled, result.outcome != .deferred, result.outcome != .unsupportedRangeAccess {
            cache?.insert(BoundedAnalysisRecord(fingerprint: fingerprint, algorithmVersion: Self.algorithmVersion,
                                                entry: result.entry, exit: result.exit, coverage: result.coverage,
                                                confidence: result.confidence, outcomeRaw: result.outcome.rawValue))
        }
        return result
    }

    private func run(source: RangeAudioSource, isCancelled: @Sendable () -> Bool) -> BoundedAnalysisResult {
        var result = BoundedAnalysisResult(outcome: .insufficientConfidence, entry: nil, exit: nil, coverage: 0,
                                           confidence: 0, decodedFrames: 0, peakBytes: 0, rangeRequests: [])
        guard source.supportsRangeAccess, source.sampleRate > 0, source.channelCount > 0 else {
            result.outcome = .unsupportedRangeAccess; return result
        }
        let rate = source.sampleRate
        let total = source.totalFrames
        guard total > 0 else { return result }
        let start = clock()
        let window = Int64(min(budget.windowSeconds, budget.maxWindowSeconds) * rate)
        let ranges: [(WindowSide, Int64, Int64)]
        if total <= window * 2 {
            ranges = [(.entry, 0, total)]
        } else {
            ranges = [(.entry, 0, window), (.exit, total - window, window)]
        }
        var deferred = false
        for (side, from, length) in ranges {
            if isCancelled() { result.outcome = .cancelled; return result }
            switch analyzeWindow(source: source, side: side, from: from, length: length, started: start,
                                 isCancelled: isCancelled, result: &result) {
            case .done(let w):
                if side == .entry { result.entry = w } else { result.exit = w }
            case .cancelled: result.outcome = .cancelled; return result
            case .deferred: deferred = true
            }
            if deferred { break }
        }
        let analysed = [result.entry, result.exit].compactMap { $0 }
        result.coverage = min(1, analysed.reduce(0) { $0 + ($1.windowEnd - $1.windowStart) } / (Double(total) / rate))
        result.confidence = analysed.map(\.confidence).min() ?? 0
        if deferred && analysed.isEmpty { result.outcome = .deferred; return result }
        if deferred { result.outcome = .deferred; return result }
        guard !analysed.isEmpty, analysed.count == ranges.count,
              analysed.allSatisfy({ $0.confidence >= budget.minimumConfidence && $0.bpm != nil }) else {
            result.outcome = .insufficientConfidence; return result
        }
        result.outcome = analysed.allSatisfy({ $0.beatCount >= budget.phraseBeats })
            ? .usablePhrasePlacement : .usableBeatPlacement
        return result
    }

    private enum WindowStep { case done(WindowAnalysis), cancelled, deferred }

    private func analyzeWindow(source: RangeAudioSource, side: WindowSide, from: Int64, length: Int64,
                               started: TimeInterval, isCancelled: @Sendable () -> Bool,
                               result: inout BoundedAnalysisResult) -> WindowStep {
        let rate = source.sampleRate, ch = source.channelCount
        var resampler = StreamingResampler(from: rate, to: budget.analysisRate)
        var mono: [Float] = []
        var cursor = from
        let end = from + length
        while cursor < end {
            if isCancelled() { return .cancelled }
            let n = Int(min(Int64(budget.chunkFrames), end - cursor))
            let chunkBytes = n * ch * MemoryLayout<Float>.size
            if clock() - started > budget.maxWallTime
                || result.decodedFrames + Int64(n) > budget.maxDecodedFrames
                || chunkBytes + mono.count * 4 > budget.maxBytes { return .deferred }
            result.rangeRequests.append((cursor, n))
            guard let pcm = try? source.decodeRange(startFrame: cursor, frameCount: n), !pcm.isEmpty else {
                return .deferred
            }
            result.peakBytes = max(result.peakBytes, pcm.count * 4 + mono.count * 4)
            let frames = pcm.count / ch
            var down = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += pcm[f * ch + c] }
                down[f] = s / Float(ch)
            }
            mono += resampler.process(down)
            result.decodedFrames += Int64(frames)
            cursor += Int64(n)
            if frames < n { break }
        }
        let t0 = Double(from) / rate
        let t1 = Double(cursor) / rate
        return .done(Self.estimate(mono, rate: budget.analysisRate, side: side, start: t0, end: t1))
    }

    /// Onset-envelope autocorrelation tempo with a beat-phase estimate.
    static func estimate(_ x: [Float], rate: Double, side: WindowSide, start: Double, end: Double) -> WindowAnalysis {
        let none = WindowAnalysis(side: side, windowStart: start, windowEnd: end, bpm: nil,
                                  firstBeatTime: nil, confidence: 0, beatCount: 0)
        let hop = 256
        let bins = x.count / hop
        guard bins > 64 else { return none }
        var env = [Float](repeating: 0, count: bins)
        for b in 0..<bins {
            var e: Float = 0
            for i in 0..<hop { let v = x[b * hop + i]; e += v * v }
            env[b] = e.squareRoot()
        }
        var onset = [Float](repeating: 0, count: bins)
        for b in 1..<bins { onset[b] = max(0, env[b] - env[b - 1]) }
        let mean = onset.reduce(0, +) / Float(bins)
        for b in 0..<bins { onset[b] = max(0, onset[b] - mean) }
        let raw0 = onset
        for b in 1..<(bins - 1) { onset[b] = raw0[b - 1] + raw0[b] + raw0[b + 1] }
        let energy = onset.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else { return none }
        let binRate = rate / Double(hop)
        let minLag = Int(binRate * 60 / 180), maxLag = min(bins / 2, Int(binRate * 60 / 60))
        guard minLag < maxLag else { return none }
        var scores = [Float](repeating: 0, count: maxLag + 1)
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            var s: Float = 0
            for i in lag..<bins { s += onset[i] * onset[i - lag] }
            scores[lag] = s
            bestScore = max(bestScore, s)
        }
        // Tolerate hop quantisation: a lag's strength includes its neighbours.
        let raw = scores
        for lag in minLag...maxLag {
            scores[lag] = raw[lag] + raw[max(minLag, lag - 1)] + raw[min(maxLag, lag + 1)]
        }
        bestScore = scores.max() ?? 0
        // Prefer the shortest lag that is nearly as strong as the best: avoids tempo-octave errors.
        var best = 0
        for lag in minLag...maxLag where scores[lag] >= 0.6 * bestScore && bestScore > 0 {
            let isPeak = scores[lag] >= scores[max(minLag, lag - 1)] && scores[lag] >= scores[min(maxLag, lag + 1)]
            if isPeak { best = lag; break }
        }
        let confidence = Double(min(1, bestScore / (3 * energy)))
        guard best > 0, confidence > 0 else { return none }
        // Phase: the offset in [0, lag) whose comb sum is largest.
        var phase = 0, phaseScore: Float = -1
        for p in 0..<best {
            var s: Float = 0, i = p
            while i < bins { s += onset[i]; i += best }
            if s > phaseScore { phaseScore = s; phase = p }
        }
        let beats = (bins - phase + best - 1) / best
        return WindowAnalysis(side: side, windowStart: start, windowEnd: end,
                              bpm: 60 * binRate / Double(best),
                              firstBeatTime: start + Double(phase) / binRate,
                              confidence: confidence, beatCount: beats)
    }
}
