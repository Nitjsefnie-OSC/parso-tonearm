#if !os(watchOS)
import AVFoundation
import XCTest
import Synchronization
@testable import TonearmCore

/// Serves a byte blob with correct `206`/`Content-Range` semantics; `override` bends individual requests.
final class StubRangeTransport: RangeTransport, @unchecked Sendable {
    typealias Override = @Sendable (_ call: Int, _ range: ClosedRange<Int64>) throws -> (Data, HTTPURLResponse)?
    let blob: Data
    let url = URL(string: "https://example.test/asset.m4a")!
    private let lock = NSLock()
    private var calls = 0
    private var ranges: [ClosedRange<Int64>] = []
    private var cancelled = false
    var override: Override?

    init(blob: Data) { self.blob = blob }

    var requestRanges: [ClosedRange<Int64>] { lock.withLock { ranges } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func response(status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func fetch(url: URL, range: ClosedRange<Int64>) throws -> (data: Data, response: HTTPURLResponse) {
        let call: Int = lock.withLock { calls += 1; ranges.append(range); return calls }
        if lock.withLock({ cancelled }) { throw URLError(.cancelled) }
        if let override, let custom = try override(call, range) { return (custom.0, custom.1) }
        let last = min(range.upperBound, Int64(blob.count) - 1)
        let body = blob.subdata(in: Int(range.lowerBound)..<Int(last + 1))
        return (body, response(status: 206, headers: ["Content-Range": "bytes \(range.lowerBound)-\(last)/\(blob.count)"]))
    }

    func cancel() { lock.withLock { cancelled = true } }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

final class ReleaseRangeReaderTests: XCTestCase {
    private func blob(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    private func reader(_ transport: StubRangeTransport, chunk: Int = 1_024, cache: Int = 4,
                        attempts: Int = 4, slept: LockedBox<[TimeInterval]>? = nil) -> ReleaseRangeReader {
        var policy = ReleaseRangeReader.Policy()
        policy.chunkBytes = chunk
        policy.maxCachedChunks = cache
        policy.maxAttempts = attempts
        policy.sleep = { delay in slept?.mutate { $0.append(delay) } }
        return ReleaseRangeReader(url: transport.url, transport: transport, policy: policy)
    }

    func testValid206AndContentRangeReturnsExactBytes() throws {
        let data = blob(10_000)
        let t = StubRangeTransport(blob: data)
        let r = reader(t)
        XCTAssertEqual(try r.totalLength(), 10_000)
        XCTAssertEqual(try r.read(offset: 1_500, count: 2_000), data.subdata(in: 1_500..<3_500))
        XCTAssertEqual(try r.read(offset: 9_900, count: 5_000), data.subdata(in: 9_900..<10_000), "clamped at end of file")
        XCTAssertEqual(try r.read(offset: 10_000, count: 10), Data())
        XCTAssertTrue(t.requestRanges.allSatisfy { $0.count <= 1_024 }, "never a whole-file request")
    }

    func testRangeRequestAsksForIdentityEncoding() {
        let request = URLSessionRangeTransport.makeRequest(url: URL(string: "https://example.test/a.m4a")!, range: 0...99)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-99")
    }

    func testEncodedPartialResponsesAreRejectedWithoutCachingOrRetry() {
        for encoding in ["gzip", "br", "deflate", "GZIP"] {
            let data = blob(5_000)
            let t = StubRangeTransport(blob: data)
            t.override = { _, range in
                let last = min(range.upperBound, Int64(data.count) - 1)
                return (data.subdata(in: Int(range.lowerBound)..<Int(last + 1)),
                        t.response(status: 206, headers: ["Content-Range": "bytes \(range.lowerBound)-\(last)/\(data.count)",
                                                          "Content-Encoding": encoding]))
            }
            let r = reader(t)
            XCTAssertThrowsError(try r.totalLength(), encoding) {
                XCTAssertEqual(($0 as? ReleaseRangeError)?.isRetryable, false)
            }
            XCTAssertEqual(t.requestRanges.count, 1, "\(encoding) is not retried")
            XCTAssertEqual(r.cachedBytes, 0)
        }
    }

    func testIdentityContentEncodingIsAccepted() throws {
        let data = blob(2_000)
        let t = StubRangeTransport(blob: data)
        t.override = { _, range in
            let last = min(range.upperBound, Int64(data.count) - 1)
            return (data.subdata(in: Int(range.lowerBound)..<Int(last + 1)),
                    t.response(status: 206, headers: ["Content-Range": "bytes \(range.lowerBound)-\(last)/\(data.count)",
                                                      "Content-Encoding": "identity"]))
        }
        XCTAssertEqual(try reader(t).read(offset: 0, count: 100), data.subdata(in: 0..<100))
    }

    func testParseContentRange() {
        XCTAssertEqual(ReleaseRangeReader.parseContentRange("bytes 0-99/1000")?.total, 1000)
        XCTAssertNil(ReleaseRangeReader.parseContentRange("bytes */1000"))
        XCTAssertNil(ReleaseRangeReader.parseContentRange("items 0-9/10"))
        XCTAssertNil(ReleaseRangeReader.parseContentRange("bytes 0-9"))
    }

    func testCacheIsBoundedWhateverTheAssetSize() throws {
        let data = blob(200_000)
        let t = StubRangeTransport(blob: data)
        let r = reader(t, chunk: 1_024, cache: 4)
        var offset: Int64 = 0
        while offset < 200_000 {
            XCTAssertEqual(try r.read(offset: offset, count: 700), data.subdata(in: Int(offset)..<min(200_000, Int(offset) + 700)))
            offset += 700
        }
        XCTAssertLessThanOrEqual(r.statistics.peakCachedBytes, 4 * 1_024)
        XCTAssertLessThanOrEqual(r.cachedBytes, 4 * 1_024)
        XCTAssertGreaterThan(r.statistics.fetchedBytes, 150_000, "the whole asset streamed through…")
        XCTAssertLessThan(r.statistics.peakCachedBytes, data.count / 10, "…without ever being held")
    }

    func testRepeatedReadsHitTheCache() throws {
        let t = StubRangeTransport(blob: blob(5_000))
        let r = reader(t)
        _ = try r.read(offset: 100, count: 100)
        let before = r.statistics.requests
        _ = try r.read(offset: 120, count: 50)
        XCTAssertEqual(r.statistics.requests, before)
    }

    func testServerIgnoringRangeIsPermanentAndNeverBuffered() {
        let data = blob(5_000)
        let t = StubRangeTransport(blob: data)
        t.override = { _, _ in (data, t.response(status: 200, headers: [:])) }
        let r = reader(t)
        XCTAssertThrowsError(try r.totalLength()) {
            XCTAssertEqual(($0 as? ReleaseRangeError)?.isRetryable, false)
        }
        XCTAssertEqual(t.requestRanges.count, 1, "a permanent failure is not retried")
        XCTAssertEqual(r.cachedBytes, 0)
    }

    func testMalformedOrMismatchedContentRangeIsPermanent() {
        for header in ["bytes 5-99/1000", "garbage", "bytes 0-99/1000x"] {
            let t = StubRangeTransport(blob: blob(1_000))
            t.override = { _, range in
                (Data(count: Int(range.count)), t.response(status: 206, headers: ["Content-Range": header]))
            }
            XCTAssertThrowsError(try reader(t).totalLength(), header) {
                XCTAssertEqual(($0 as? ReleaseRangeError)?.isRetryable, false)
            }
        }
    }

    func testBodyShorterThanContentRangeIsPermanent() {
        let t = StubRangeTransport(blob: blob(1_000))
        t.override = { _, range in
            (Data(count: 10), t.response(status: 206, headers: ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/1000"]))
        }
        XCTAssertThrowsError(try reader(t).totalLength()) {
            XCTAssertEqual(($0 as? ReleaseRangeError)?.isRetryable, false)
        }
    }

    func testInternallyShort206IsRejectedAndNeverCached() throws {
        let data = blob(5_000)
        let t = StubRangeTransport(blob: data)
        // Nominal chunk is 1024 bytes, but the server stops 100 bytes early with a coherent header.
        t.override = { _, range in
            let last = range.upperBound - 100
            return (data.subdata(in: Int(range.lowerBound)..<Int(last + 1)),
                    t.response(status: 206, headers: ["Content-Range": "bytes \(range.lowerBound)-\(last)/5000"]))
        }
        let r = reader(t)
        XCTAssertThrowsError(try r.totalLength()) {
            XCTAssertEqual(($0 as? ReleaseRangeError)?.isRetryable, false)
        }
        XCTAssertEqual(t.requestRanges.count, 1, "no retry of an invalid response")
        XCTAssertEqual(r.cachedBytes, 0)
    }

    func testFinalEOFChunkShorterThanNominalIsAccepted() throws {
        let data = blob(2_500)                                 // chunks 1024, 1024, 452
        let t = StubRangeTransport(blob: data)
        let r = reader(t)
        XCTAssertEqual(try r.read(offset: 2_000, count: 1_000), data.subdata(in: 2_000..<2_500))
    }

    func testBoundsAndTotalLengthMustAgree() {
        let cases: [(String, Int)] = [
            ("bytes 0-1023/1000", 1_024),     // total smaller than the last byte
            ("bytes 0-1022/5000", 1_024),     // short and not at EOF
            ("bytes 0-1023/5000", 1_000),     // body shorter than the range
            ("bytes 0-1023/5000", 1_030),     // body longer than the range
            ("bytes 0-2047/5000", 2_048)      // beyond the requested last byte
        ]
        for (header, bodySize) in cases {
            let t = StubRangeTransport(blob: blob(5_000))
            t.override = { _, _ in (Data(count: bodySize), t.response(status: 206, headers: ["Content-Range": header])) }
            let r = reader(t)
            XCTAssertThrowsError(try r.totalLength(), header) {
                XCTAssertEqual(($0 as? ReleaseRangeError)?.isRetryable, false, header)
            }
            XCTAssertEqual(r.cachedBytes, 0, header)
        }
    }

    func testTotalLengthChangingBetweenChunksIsRejected() throws {
        let data = blob(5_000)
        let t = StubRangeTransport(blob: data)
        t.override = { call, range in
            guard call == 2 else { return nil }
            return (data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1)),
                    t.response(status: 206, headers: ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/9999"]))
        }
        let r = reader(t)
        _ = try r.read(offset: 0, count: 10)
        XCTAssertThrowsError(try r.read(offset: 1_100, count: 10))
    }

    func testMissingAssetIsPermanentWithoutRetry() {
        for status in [404, 410, 416, 403] {
            let t = StubRangeTransport(blob: blob(10))
            t.override = { _, _ in (Data(), t.response(status: status, headers: [:])) }
            XCTAssertThrowsError(try reader(t).totalLength(), "\(status)") {
                XCTAssertEqual(($0 as? ReleaseRangeError)?.isRetryable, false)
            }
            XCTAssertEqual(t.requestRanges.count, 1)
        }
    }

    func testTransientFailuresRetryWithBackoffThenSucceed() throws {
        let data = blob(3_000)
        let t = StubRangeTransport(blob: data)
        t.override = { call, _ in
            if call == 1 { throw URLError(.timedOut) }
            if call == 2 { return (Data(), t.response(status: 503, headers: [:])) }
            if call == 3 { return (Data(), t.response(status: 429, headers: [:])) }
            return nil
        }
        let slept = LockedBox<[TimeInterval]>([])
        let r = reader(t, attempts: 4, slept: slept)
        XCTAssertEqual(try r.read(offset: 0, count: 100), data.subdata(in: 0..<100))
        XCTAssertEqual(t.requestRanges.count, 4)
        let delays = slept.value
        XCTAssertEqual(delays.count, 3)
        XCTAssertEqual(delays, delays.sorted(), "backoff never shrinks")
        XCTAssertGreaterThan(delays[2], delays[0])
    }

    func testTransientFailuresOutliveRetriesAsRetryable() {
        let t = StubRangeTransport(blob: blob(10))
        t.override = { _, _ in throw URLError(.notConnectedToInternet) }
        let slept = LockedBox<[TimeInterval]>([])
        XCTAssertThrowsError(try reader(t, attempts: 3, slept: slept).totalLength()) {
            XCTAssertEqual(($0 as? ReleaseRangeError)?.isRetryable, true)
        }
        XCTAssertEqual(t.requestRanges.count, 3, "bounded attempts")
        XCTAssertEqual(slept.value.count, 2)
    }

    func testCancellationStopsReadsAndRetries() throws {
        let t = StubRangeTransport(blob: blob(10_000))
        let r = reader(t)
        _ = try r.read(offset: 0, count: 10)
        let before = t.requestRanges.count
        r.cancel()
        XCTAssertTrue(t.wasCancelled)
        XCTAssertThrowsError(try r.read(offset: 5_000, count: 10)) {
            XCTAssertEqual($0 as? ReleaseRangeError, .cancelled)
        }
        XCTAssertEqual(t.requestRanges.count, before, "no request after cancel")
    }

    func testCancelDuringBackoffDoesNotRetry() {
        let t = StubRangeTransport(blob: blob(10))
        t.override = { _, _ in throw URLError(.timedOut) }
        var policy = ReleaseRangeReader.Policy()
        let holder = LockedBox<ReleaseRangeReader?>(nil)
        policy.sleep = { _ in holder.value?.cancel() }
        let r = ReleaseRangeReader(url: t.url, transport: t, policy: policy)
        holder.mutate { $0 = r }
        XCTAssertThrowsError(try r.totalLength()) { XCTAssertEqual($0 as? ReleaseRangeError, .cancelled) }
        XCTAssertEqual(t.requestRanges.count, 1)
    }

    // MARK: Real AAC decode through the range reader

    /// A real AAC-LC M4A (CoreAudio encoder): a 440 Hz tone, long enough to span many chunks.
    private func writeTone(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100.0,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 44_100) }
        }
        try file.write(from: buffer)
    }   // the file is released here, which writes the moov atom

    /// A real AAC-LC M4A (CoreAudio encoder): a 440 Hz tone, long enough to span many chunks.
    private func makeM4A(seconds: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rr-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTone(to: url, seconds: seconds)
        return try Data(contentsOf: url)
    }

    func testDecodesMidFileWindowFromRangesWithBoundedMemoryAndNoTempFile() throws {
        let m4a = try makeM4A(seconds: 40)
        XCTAssertGreaterThan(m4a.count, 300_000)
        let tempBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        let t = StubRangeTransport(blob: m4a)
        let r = reader(t, chunk: 16_384, cache: 4)
        let source = try ReleaseM4ADeckSource(reader: r)
        XCTAssertEqual(source.sampleRate, 44_100)
        XCTAssertEqual(Double(source.totalFrames) / 44_100, 40, accuracy: 0.1)

        let start: Int64 = 25 * 44_100
        let planes = try source.read(startFrame: start, count: 8_192)
        XCTAssertEqual(planes.count, 2)
        XCTAssertEqual(planes[0].count, 8_192)
        // 440 Hz is there (Goertzel), 1 kHz is not.
        XCTAssertGreaterThan(goertzel(planes[0], freq: 440), 50 * goertzel(planes[0], freq: 1_000))

        XCTAssertLessThan(r.statistics.fetchedBytes, Int64(m4a.count) / 2, "only the index and the window were fetched")
        XCTAssertLessThanOrEqual(r.statistics.peakCachedBytes, 4 * 16_384)
        // Seeking backwards works and stays windowed.
        let early = try source.read(startFrame: 1_000, count: 4_096)
        XCTAssertGreaterThan(goertzel(early[0], freq: 440), 50 * goertzel(early[0], freq: 1_000))
        XCTAssertLessThan(r.statistics.fetchedBytes, Int64(m4a.count))
        let tempAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        XCTAssertEqual(tempAfter.filter { $0.hasSuffix(".m4a") }.subtracting(tempBefore).count, 0,
                       "no temporary reconstruction of the asset")
    }

    func testCancelledDecodeThrowsAndPermanentRangeFailureSurfacesFromOpen() throws {
        let m4a = try makeM4A(seconds: 5)
        let t = StubRangeTransport(blob: m4a)
        let source = try ReleaseM4ADeckSource(reader: reader(t, chunk: 8_192, cache: 2))
        source.cancel()
        XCTAssertThrowsError(try source.read(startFrame: 100_000, count: 4_096))

        let gone = StubRangeTransport(blob: Data())
        gone.override = { _, _ in (Data(), gone.response(status: 404, headers: [:])) }
        XCTAssertThrowsError(try ReleaseM4ADeckSource(reader: reader(gone))) {
            XCTAssertEqual(($0 as? ReleaseRangeError)?.isRetryable, false)
        }
        let notAudio = StubRangeTransport(blob: Data(repeating: 7, count: 50_000))
        XCTAssertThrowsError(try ReleaseM4ADeckSource(reader: reader(notAudio)))
    }

    private func goertzel(_ x: [Float], freq: Double, rate: Double = 44_100) -> Double {
        let w = 2 * Double.pi * freq / rate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s = Double(v) + coeff * s1 - s2; s2 = s1; s1 = s }
        return (s1 * s1 + s2 * s2 - coeff * s1 * s2).squareRoot() / Double(x.count)
    }
}
#endif
