import XCTest
@testable import TonearmCore

final class BoundedWindowAnalysisTests: XCTestCase {
    /// Synthetic click track generated lazily; never materialises the whole file.
    private final class Click: RangeAudioSource, @unchecked Sendable {
        let sampleRate: Double, channelCount = 2, totalFrames: Int64
        let supportsRangeAccess: Bool
        let bpm: Double, silent: Bool
        let lock = NSLock(); private var calls: [(Int64, Int)] = []
        init(seconds: Double, rate: Double = 44_100, bpm: Double = 120, range: Bool = true, silent: Bool = false) {
            sampleRate = rate; totalFrames = Int64(seconds * rate); self.bpm = bpm
            supportsRangeAccess = range; self.silent = silent
        }
        var requests: [(Int64, Int)] { lock.withLock { calls } }
        func decodeRange(startFrame: Int64, frameCount: Int) throws -> [Float] {
            lock.withLock { calls.append((startFrame, frameCount)) }
            let n = Int(min(Int64(frameCount), totalFrames - startFrame))
            var out = [Float](repeating: 0, count: max(0, n) * 2)
            if silent { return out }
            let period = 60 / bpm
            for f in 0..<max(0, n) {
                let t = Double(startFrame + Int64(f)) / sampleRate
                let ph = t.truncatingRemainder(dividingBy: period)
                if ph < 0.03 { let v = Float(exp(-ph * 120)); out[f * 2] = v; out[f * 2 + 1] = v }
            }
            return out
        }
    }

    func testShortFixtureUsable() {
        let r = BoundedWindowAnalyzer().analyze(source: Click(seconds: 40), fingerprint: "a")
        XCTAssertTrue([.usableBeatPlacement, .usablePhrasePlacement].contains(r.outcome))
        XCTAssertEqual(r.entry?.bpm ?? 0, 120, accuracy: 3)
    }

    func testLongTrackSameMemoryBoundAndDirectTailSeek() {
        let short = Click(seconds: 300), long = Click(seconds: 3 * 3600)
        let a = BoundedWindowAnalyzer(), s = a.analyze(source: short, fingerprint: "s")
        let l = a.analyze(source: long, fingerprint: "l")
        XCTAssertEqual(s.peakBytes, l.peakBytes, accuracy: s.peakBytes / 4)
        XCTAssertLessThanOrEqual(l.peakBytes, a.budget.maxBytes)
        XCTAssertEqual(l.decodedFrames, Int64(2 * 30 * 44_100))
        let tailStart = long.totalFrames - Int64(30 * 44_100)
        XCTAssertEqual(long.requests.map(\.0).filter { $0 >= Int64(30 * 44_100) && $0 < tailStart }.count, 0)
        XCTAssertEqual(long.requests.last!.0 + Int64(long.requests.last!.1), long.totalFrames)
        XCTAssertLessThan(l.coverage, 0.01)
        XCTAssertFalse(l.claimsFullTrackStructure); XCTAssertFalse(l.claimsInteriorDoubleDrop)
    }

    func testResamplerChunkJoinsMatchOneShot() {
        let x = (0..<10_001).map { Float(sin(Double($0) * 0.01)) }
        var one = StreamingResampler(from: 44_100, to: 11_025)
        let whole = one.process(x)
        var chunked = StreamingResampler(from: 44_100, to: 11_025)
        var parts: [Float] = []
        for s in stride(from: 0, to: x.count, by: 777) { parts += chunked.process(Array(x[s..<min(s + 777, x.count)])) }
        XCTAssertEqual(parts.count, whole.count)
        for (p, w) in zip(parts, whole) { XCTAssertEqual(p, w, accuracy: 1e-5) }
    }

    func testSilenceIsInsufficient() {
        let r = BoundedWindowAnalyzer().analyze(source: Click(seconds: 100, silent: true), fingerprint: "z")
        XCTAssertEqual(r.outcome, .insufficientConfidence)
        XCTAssertEqual(r.confidence, 0)
    }

    func testUnsupportedRangeAccessNeverDecodes() {
        let c = Click(seconds: 100, range: false)
        let r = BoundedWindowAnalyzer().analyze(source: c, fingerprint: "u")
        XCTAssertEqual(r.outcome, .unsupportedRangeAccess)
        XCTAssertTrue(c.requests.isEmpty)
    }

    func testCancellationPreventsLaterChunks() {
        let c = Click(seconds: 600)
        let n = NSLock(); nonisolated(unsafe) var seen = 0
        let r = BoundedWindowAnalyzer().analyze(source: c, fingerprint: "c") {
            n.withLock { seen += 1; return seen > 2 }
        }
        XCTAssertEqual(r.outcome, .cancelled)
        XCTAssertLessThanOrEqual(c.requests.count, 2)
    }

    func testBudgetsDefer() {
        var b = WindowAnalysisBudget(); b.maxDecodedFrames = 100_000
        let r = BoundedWindowAnalyzer(budget: b).analyze(source: Click(seconds: 600), fingerprint: "d")
        XCTAssertEqual(r.outcome, .deferred)
        XCTAssertLessThanOrEqual(r.decodedFrames, 100_000)
    }

    func testCacheKeyedByFingerprintAndVersion() {
        let cache = BoundedAnalysisCache(), c = Click(seconds: 100)
        let a = BoundedWindowAnalyzer()
        _ = a.analyze(source: c, fingerprint: "f", cache: cache)
        let n = c.requests.count
        let hit = a.analyze(source: c, fingerprint: "f", cache: cache)
        XCTAssertEqual(c.requests.count, n); XCTAssertEqual(hit.decodedFrames, 0)
        XCTAssertNil(cache.record(fingerprint: "f", version: 999))
        _ = a.analyze(source: c, fingerprint: "g", cache: cache)
        XCTAssertGreaterThan(c.requests.count, n)
    }
}
