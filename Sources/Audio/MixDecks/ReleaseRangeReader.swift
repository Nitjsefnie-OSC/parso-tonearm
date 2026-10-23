#if !os(watchOS)
import Foundation
import Synchronization

/// Why a release asset could not be read. `isRetryable` is what the UI may offer a Retry for;
/// a permanent failure never retries by itself.
enum ReleaseRangeError: Error, Equatable, LocalizedError {
    /// Transport, timeout, 429 or 5xx that outlived the bounded retries.
    case transient(String)
    /// 404/410/416, a server that ignores `Range`, or a response that breaks the range contract.
    case permanent(String)
    case cancelled

    var isRetryable: Bool {
        if case .transient = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .transient(let detail): return "The audio could not be reached right now (\(detail))."
        case .permanent(let detail): return "This audio file is unavailable (\(detail))."
        case .cancelled: return "Loading was cancelled."
        }
    }
}

/// One blocking HTTP range request. Blocking is deliberate: it is only called from decode threads
/// that already wait on I/O, never from the audio render callback or the cooperative pool.
protocol RangeTransport: Sendable {
    func fetch(url: URL, range: ClosedRange<Int64>) throws -> (data: Data, response: HTTPURLResponse)
    /// Aborts the request in flight and makes later ones throw `URLError.cancelled`.
    func cancel()
}

/// URLSession-backed transport. Never follows a request into a whole-file `200`: the caller
/// rejects that.
final class URLSessionRangeTransport: RangeTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    /// Asks for identity encoding so byte offsets and body length mean the same thing.
    static func makeRequest(url: URL, range: ClosedRange<Int64>) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    func fetch(url: URL, range: ClosedRange<Int64>) throws -> (data: Data, response: HTTPURLResponse) {
        let request = Self.makeRequest(url: url, range: range)
        let box = Mutex<Result<(Data, HTTPURLResponse), any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            if let error { box.withLock { $0 = .failure(error) } }
            else if let http = response as? HTTPURLResponse { box.withLock { $0 = .success((data ?? Data(), http)) } }
            else { box.withLock { $0 = .failure(URLError(.badServerResponse)) } }
            done.signal()
        }
        let proceed: Bool = lock.withLock {
            guard !cancelled else { return false }
            self.task = task
            return true
        }
        guard proceed else { throw URLError(.cancelled) }
        task.resume()
        done.wait()
        switch box.withLock({ $0 }) {
        case .success(let value)?: return (value.0, value.1)
        case .failure(let error)?: throw error
        case nil: throw URLError(.unknown)
        }
    }

    func cancel() {
        let pending: URLSessionDataTask? = lock.withLock {
            cancelled = true
            return task
        }
        pending?.cancel()
    }
}

/// Reads one release asset by byte range with bounded memory: aligned chunks in a small LRU cache,
/// never the whole file and never a temporary reconstruction. Every response is validated
/// (`206`, a `Content-Range` that matches the request, a body of exactly that length); a `200`
/// whole-body answer is a permanent failure rather than something to buffer.
final class ReleaseRangeReader: @unchecked Sendable {
    struct Policy: Sendable {
        var chunkBytes = 256 * 1024
        var maxCachedChunks = 8
        /// Attempts per chunk for transient failures, with `backoff` between them.
        var maxAttempts = 4
        var backoff: @Sendable (_ attempt: Int) -> TimeInterval = { 0.4 * pow(2, Double($0 - 1)) }
        var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    }

    let url: URL
    private let transport: any RangeTransport
    private let policy: Policy
    private let lock = NSLock()
    private var length: Int64?
    private var cache: [Int64: Data] = [:]      // chunk index → bytes
    private var recency: [Int64] = []           // least recent first
    private var cancelled = false
    private var requests = 0
    private var fetched: Int64 = 0
    private var peakCached = 0

    init(url: URL, transport: any RangeTransport = URLSessionRangeTransport(), policy: Policy = Policy()) {
        self.url = url
        self.transport = transport
        self.policy = policy
    }

    /// Requests made, bytes fetched and the most bytes ever held (the bound a test asserts).
    var statistics: (requests: Int, fetchedBytes: Int64, peakCachedBytes: Int) {
        lock.withLock { (requests, fetched, peakCached) }
    }
    var cachedBytes: Int { lock.withLock { cache.values.reduce(0) { $0 + $1.count } } }

    func cancel() {
        lock.withLock { cancelled = true }
        transport.cancel()
    }

    /// Total asset size, learned from the first `Content-Range`.
    func totalLength() throws -> Int64 {
        if let known = lock.withLock({ length }) { return known }
        _ = try chunk(0)
        guard let known = lock.withLock({ length }) else { throw ReleaseRangeError.permanent("unknown length") }
        return known
    }

    /// Up to `count` bytes at `offset` (fewer at end of file).
    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        let total = try totalLength()
        guard offset < total else { return Data() }
        let end = min(total, offset + Int64(count))
        var out = Data()
        out.reserveCapacity(Int(end - offset))
        var position = offset
        let size = Int64(policy.chunkBytes)
        while position < end {
            let index = position / size
            let data = try chunk(index)
            let start = Int(position - index * size)
            guard start < data.count else { throw ReleaseRangeError.permanent("short chunk") }
            let take = min(data.count - start, Int(end - position))
            out.append(data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + take)))
            position += Int64(take)
        }
        return out
    }

    private func chunk(_ index: Int64) throws -> Data {
        if let hit: Data = lock.withLock({
            guard let data = cache[index] else { return nil }
            recency.removeAll { $0 == index }
            recency.append(index)
            return data
        }) { return hit }
        let data = try fetchChunk(index)
        lock.withLock {
            cache[index] = data
            recency.removeAll { $0 == index }
            recency.append(index)
            while cache.count > policy.maxCachedChunks, let oldest = recency.first {
                recency.removeFirst()
                cache[oldest] = nil
            }
            peakCached = max(peakCached, cache.values.reduce(0) { $0 + $1.count })
        }
        return data
    }

    private func fetchChunk(_ index: Int64) throws -> Data {
        let size = Int64(policy.chunkBytes)
        let first = index * size
        var lastError: ReleaseRangeError = .transient("no attempt")
        for attempt in 1...max(1, policy.maxAttempts) {
            if lock.withLock({ cancelled }) { throw ReleaseRangeError.cancelled }
            if attempt > 1 { policy.sleep(policy.backoff(attempt - 1)) }
            if lock.withLock({ cancelled }) { throw ReleaseRangeError.cancelled }
            let known = lock.withLock { length }
            let last = known.map { min($0, first + size) - 1 } ?? first + size - 1
            lock.withLock { requests += 1 }
            do {
                let (data, response) = try transport.fetch(url: url, range: first...max(first, last))
                return try validate(data, response, first: first, requestedLast: max(first, last))
            } catch let error as ReleaseRangeError {
                if case .transient = error { lastError = error; continue }
                throw error
            } catch let error as URLError {
                if error.code == .cancelled || lock.withLock({ cancelled }) { throw ReleaseRangeError.cancelled }
                lastError = .transient(error.localizedDescription)
            } catch {
                lastError = .transient(error.localizedDescription)
            }
        }
        throw lastError
    }

    private func validate(_ data: Data, _ response: HTTPURLResponse, first: Int64,
                          requestedLast: Int64) throws -> Data {
        switch response.statusCode {
        case 206: break
        case 200: throw ReleaseRangeError.permanent("server ignored the byte range")
        case 404, 410: throw ReleaseRangeError.permanent("not found (HTTP \(response.statusCode))")
        case 416: throw ReleaseRangeError.permanent("range not satisfiable")
        case 408, 425, 429, 500...599: throw ReleaseRangeError.transient("HTTP \(response.statusCode)")
        default: throw ReleaseRangeError.permanent("HTTP \(response.statusCode)")
        }
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespaces).lowercased(), !encoding.isEmpty, encoding != "identity" {
            throw ReleaseRangeError.permanent("encoded range response (\(encoding))")
        }
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              let parsed = Self.parseContentRange(header) else {
            throw ReleaseRangeError.permanent("missing or malformed Content-Range")
        }
        guard parsed.first == first, parsed.last >= parsed.first, parsed.last <= requestedLast,
              parsed.total > parsed.last,
              Int64(data.count) == parsed.last - parsed.first + 1 else {
            throw ReleaseRangeError.permanent("Content-Range does not match the request")
        }
        // Only the real end of the resource may be shorter than requested.
        guard parsed.last == requestedLast || parsed.last == parsed.total - 1 else {
            throw ReleaseRangeError.permanent("truncated partial response")
        }
        if let known = lock.withLock({ length }), known != parsed.total {
            throw ReleaseRangeError.permanent("total length changed")
        }
        lock.withLock {
            length = parsed.total
            fetched += Int64(data.count)
        }
        return data
    }

    /// `bytes first-last/total`.
    static func parseContentRange(_ value: String) -> (first: Int64, last: Int64, total: Int64)? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/")
        guard rangeAndTotal.count == 2, let total = Int64(rangeAndTotal[1]), total > 0 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-")
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]) else { return nil }
        return (first, last, total)
    }
}
#endif
