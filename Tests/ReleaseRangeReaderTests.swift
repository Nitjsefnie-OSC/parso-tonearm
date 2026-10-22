import XCTest
@testable import TonearmCore

/// Serves a byte array the way a release host does, with scriptable misbehaviour.
private final class StubHost: RangeTransport, @unchecked Sendable {
    let url: URL
    let body: Data
    private let lock = NSLock()
    private var _requests: [String] = []
    private var script: [(URLRequest) throws -> (Data, HTTPURLResponse)?] = []

    init(url: URL, size: Int) {
        self.url = url
        body = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    var requests: [String] { lock.withLock { _requests } }

    /// Consumed one per request, ahead of the normal behaviour; returning nil falls through to it.
    func enqueue(_ step: @escaping (URLRequest) throws -> (Data, HTTPURLResponse)?) {
        lock.withLock { script.append(step) }
    }

    func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step: ((URLRequest) throws -> (Data, HTTPURLResponse)?)? = lock.withLock {
            _requests.append(request.value(forHTTPHeaderField: "Range") ?? "")
            return script.isEmpty ? nil : script.removeFirst()
        }
        if let step, let result = try step(request) { return result }
        let header = request.value(forHTTPHeaderField: "Range") ?? ""
        let nums = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int($0) }
        guard nums.count == 2 else { return (body, response(200)) }
        if nums[0] >= body.count {
            return (Data(), response(416, headers: ["Content-Range": "bytes */\(body.count)"]))
        }
        let last = min(nums[1], body.count - 1)
        return (body.subdata(in: nums[0]..<(last + 1)),
                response(206, headers: ["Content-Range": "bytes \(nums[0])-\(last)/\(body.count)"]))
    }
}

final class ReleaseRangeReaderTests: XCTestCase {
    private let url = StarterBlendPack.assetURL(trackID: "337997")

    private func reader(_ host: StubHost, chunk: Int = 100, budget: Int = 1_000,
                        attempts: Int = 3, delays: DelayLog = DelayLog()) -> ReleaseRangeReader {
        ReleaseRangeReader(url: url, transport: host, policy: RangeRetryPolicy(maxAttempts: attempts, baseDelay: 1, maxDelay: 4),
                           chunkSize: chunk, cacheBudget: budget, sleep: { delays.add($0) })
    }

    func testValid206ReturnsExactBytesAndReportsLength() async throws {
        let host = StubHost(url: url, size: 450)
        let r = reader(host)
        let data = try await r.read(offset: 130, length: 200)
        XCTAssertEqual(data, host.body.subdata(in: 130..<330))
        let length = try await r.contentLength()
        XCTAssertEqual(length, 450)
    }

    func testReadClampsAtEndOfAsset() async throws {
        let host = StubHost(url: url, size: 450)
        let r = reader(host)
        let data = try await r.read(offset: 400, length: 500)
        XCTAssertEqual(data, host.body.subdata(in: 400..<450))
        let past = try await r.read(offset: 450, length: 10)
        XCTAssertTrue(past.isEmpty)
    }

    func testContentLengthProbeRequestsOneByte() async throws {
        let host = StubHost(url: url, size: 450)
        let length = try await reader(host).contentLength()
        XCTAssertEqual(length, 450)
        XCTAssertEqual(host.requests, ["bytes=0-0"])
    }

    func testCachedRangesMakeNoSecondRequest() async throws {
        let host = StubHost(url: url, size: 450)
        let r = reader(host)
        _ = try await r.read(offset: 0, length: 250)
        let count = host.requests.count
        let again = try await r.read(offset: 50, length: 100)
        XCTAssertEqual(again, host.body.subdata(in: 50..<150))
        XCTAssertEqual(host.requests.count, count)
    }

    func testCacheStaysWithinBudget() async throws {
        let host = StubHost(url: url, size: 2_000)
        let r = reader(host, chunk: 100, budget: 300)
        _ = try await r.read(offset: 0, length: 2_000)
        let held = await r.cachedByteCount
        XCTAssertLessThanOrEqual(held, 300)
    }

    func testStatus200ToARangeRequestIsRejected() async {
        let host = StubHost(url: url, size: 450)
        host.enqueue { _ in (host.body, host.response(200)) }
        do {
            _ = try await reader(host).read(offset: 0, length: 10)
            XCTFail("expected failure")
        } catch let error as RangeFetchError {
            guard case .invalidResponse = error else { return XCTFail("\(error)") }
            XCTAssertFalse(error.isRetryable)
        } catch { XCTFail("\(error)") }
    }

    func testMismatchedContentRangeIsRejected() async {
        let host = StubHost(url: url, size: 450)
        host.enqueue { _ in (Data(count: 100), host.response(206, headers: ["Content-Range": "bytes 100-199/450"])) }
        do {
            _ = try await reader(host).read(offset: 0, length: 10)
            XCTFail("expected failure")
        } catch let error as RangeFetchError {
            guard case .invalidResponse = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    func testMissingContentRangeAndShortBodyAreRejected() async {
        let host = StubHost(url: url, size: 450)
        host.enqueue { _ in (Data(count: 100), host.response(206)) }
        host.enqueue { _ in (Data(count: 40), host.response(206, headers: ["Content-Range": "bytes 0-99/450"])) }
        let r = reader(host, attempts: 1)
        for _ in 0..<2 {
            do { _ = try await r.read(offset: 0, length: 10); XCTFail("expected failure") }
            catch let error as RangeFetchError { guard case .invalidResponse = error else { return XCTFail("\(error)") } }
            catch { XCTFail("\(error)") }
        }
    }

    func testValidShortFinalRangeIsAccepted() async throws {
        let host = StubHost(url: url, size: 450)
        let r = reader(host)
        let data = try await r.read(offset: 440, length: 10)
        XCTAssertEqual(data, host.body.subdata(in: 440..<450))
    }

    func testTransientFailuresRetryWithBoundedBackoff() async throws {
        let host = StubHost(url: url, size: 450)
        host.enqueue { _ in (Data(), host.response(503)) }
        host.enqueue { _ in (Data(), host.response(429, headers: ["Retry-After": "3"])) }
        let delays = DelayLog()
        let r = reader(host, attempts: 4, delays: delays)
        let data = try await r.read(offset: 0, length: 50)
        XCTAssertEqual(data, host.body.subdata(in: 0..<50))
        XCTAssertEqual(delays.values, [1, 3])
    }

    func testRetriesAreBoundedThenReportedRetryable() async {
        let host = StubHost(url: url, size: 450)
        for _ in 0..<10 { host.enqueue { _ in (Data(), host.response(503)) } }
        let r = reader(host, attempts: 3)
        do {
            _ = try await r.read(offset: 0, length: 50)
            XCTFail("expected failure")
        } catch let error as RangeFetchError {
            XCTAssertTrue(error.isRetryable)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(host.requests.count, 3)
    }

    func testNotFoundIsPermanentAndNotRetried() async {
        let host = StubHost(url: url, size: 450)
        host.enqueue { _ in (Data(), host.response(404)) }
        let delays = DelayLog()
        do {
            _ = try await reader(host, delays: delays).read(offset: 0, length: 50)
            XCTFail("expected failure")
        } catch let error as RangeFetchError {
            guard case .permanent = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(host.requests.count, 1)
        XCTAssertTrue(delays.values.isEmpty)
    }

    func testExpiredRedirectTargetIsRefreshedFromTheCanonicalURL() async throws {
        let host = StubHost(url: url, size: 450)
        host.enqueue { _ in (Data(), host.response(403)) }
        let r = reader(host)
        let data = try await r.read(offset: 0, length: 50)
        XCTAssertEqual(data, host.body.subdata(in: 0..<50))
        let refreshes = await r.refreshCount
        XCTAssertEqual(refreshes, 1)
    }

    func testPersistent403IsPermanentAfterOneRefresh() async {
        let host = StubHost(url: url, size: 450)
        for _ in 0..<5 { host.enqueue { _ in (Data(), host.response(403)) } }
        do {
            _ = try await reader(host).read(offset: 0, length: 50)
            XCTFail("expected failure")
        } catch let error as RangeFetchError {
            guard case .permanent = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(host.requests.count, 2)
    }

    func testNetworkErrorsAreRetryable() async throws {
        let host = StubHost(url: url, size: 450)
        host.enqueue { _ in throw URLError(.networkConnectionLost) }
        let data = try await reader(host).read(offset: 0, length: 20)
        XCTAssertEqual(data.count, 20)
    }

    func testCancellationStopsTheRead() async {
        let host = StubHost(url: url, size: 450)
        let r = ReleaseRangeReader(url: url, transport: host, chunkSize: 100, cacheBudget: 1_000,
                                   sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) })
        host.enqueue { _ in (Data(), host.response(503)) }
        let task = Task { try await r.read(offset: 0, length: 300) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
    }

    func testContentRangeParsing() {
        XCTAssertEqual(ContentRange(header: "bytes 0-99/450"), ContentRange(header: " bytes 0-99/450 "))
        XCTAssertEqual(ContentRange(header: "bytes 5-9/*")?.total, nil)
        XCTAssertNil(ContentRange(header: "bytes 9-5/450"))
        XCTAssertNil(ContentRange(header: "bytes 0-99/50"))
        XCTAssertNil(ContentRange(header: "items 0-9/10"))
        XCTAssertNil(ContentRange(header: "bytes */450"))
    }

    func testReleaseAssetDownloadStreamsEveryByteThroughTheReader() async throws {
        let host = StubHost(url: url, size: 3_000)
        let r = reader(host, chunk: 256, budget: 1_024)
        let file = try await MixTrackLoader.downloadReleaseAsset(url, reader: r) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), host.body)
        XCTAssertTrue(host.requests.allSatisfy { $0.hasPrefix("bytes=") }, "only ranged requests")
    }

    func testReleaseAssetOutageSurfacesAsRetryableLoaderError() async {
        let host = StubHost(url: url, size: 3_000)
        for _ in 0..<10 { host.enqueue { _ in (Data(), host.response(503)) } }
        do {
            _ = try await MixTrackLoader.downloadReleaseAsset(url, reader: reader(host, attempts: 2)) { _ in }
            XCTFail("expected failure")
        } catch let error as MixTrackLoaderError {
            guard case .releaseAssetUnavailable(_, let retryable) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(retryable)
        } catch { XCTFail("\(error)") }
    }
}

private final class DelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { _values } }
    func add(_ value: TimeInterval) { lock.withLock { _values.append(value) } }
}
