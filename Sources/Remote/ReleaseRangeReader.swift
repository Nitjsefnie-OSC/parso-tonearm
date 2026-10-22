import Foundation

/// How one HTTP request is sent. `URLSession` in the app; a stub in tests.
public protocol RangeTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionRangeTransport: RangeTransport {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Why a ranged read failed, split by whether trying again can help.
public enum RangeFetchError: Error, Equatable, Sendable {
    /// Timeouts, dropped connections, 408/429/5xx: worth another bounded attempt.
    case retryable(String)
    /// 404, other 4xx, an unsatisfiable range: the asset is not there; retrying will not help.
    case permanent(String)
    /// The server answered, but not with the exact bytes asked for (a 200 to a Range request, a
    /// `Content-Range` that does not match, a short body).
    case invalidResponse(String)

    public var isRetryable: Bool { if case .retryable = self { true } else { false } }

    public var message: String {
        switch self {
        case .retryable(let m), .permanent(let m), .invalidResponse(let m): m
        }
    }
}

/// A parsed `Content-Range: bytes first-last/total` header (`total` nil for `*`).
struct ContentRange: Equatable {
    let first: Int64
    let last: Int64
    let total: Int64?

    init?(header: String) {
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]),
              first >= 0, last >= first else { return nil }
        if rangeAndTotal[1] == "*" {
            total = nil
        } else {
            guard let total = Int64(rangeAndTotal[1]), total > last else { return nil }
            self.total = total
        }
        self.first = first
        self.last = last
    }
}

/// Bounded exponential backoff for intermittent release URLs.
public struct RangeRetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 4, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 4) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Delay before retry number `attempt` (1 is the first retry), honouring a server `Retry-After`.
    func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let backoff = min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
        return min(maxDelay, max(backoff, retryAfter ?? 0))
    }
}

/// Reads one release asset in HTTP byte ranges, only ever asking for the bytes needed.
///
/// - A range is served from `206 Partial Content` only: the `Content-Range` must start where the
///   request did, stay inside it and match the body length. A `200` (range ignored) is an error.
/// - Fetched bytes are kept in fixed-size chunks under a byte budget (least recently used first), so
///   re-reading a range, or an overlapping one, makes no request.
/// - Transient failures retry with bounded backoff; `403`/`410` (an expired redirect target) re-resolve
///   the canonical release URL once before counting as a failure; `404` and other 4xx are permanent.
/// - Cancelling the calling task stops the read between requests and during a backoff sleep.
public actor ReleaseRangeReader {
    public static let defaultChunkSize = 256 * 1024

    public let url: URL
    private let transport: RangeTransport
    private let policy: RangeRetryPolicy
    private let chunkSize: Int
    private let cacheBudget: Int
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var chunks: [Int64: Data] = [:]
    private var recency: [Int64] = []
    private var cachedBytes = 0
    private var knownLength: Int64?
    private var resolvedURL: URL?
    public private(set) var requestCount = 0
    public private(set) var refreshCount = 0

    public init(url: URL, transport: RangeTransport = URLSessionRangeTransport(),
                policy: RangeRetryPolicy = RangeRetryPolicy(), chunkSize: Int = defaultChunkSize,
                cacheBudget: Int = 8 * 1024 * 1024,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                }) {
        self.url = url
        self.transport = transport
        self.policy = policy
        self.chunkSize = max(1, chunkSize)
        self.cacheBudget = max(chunkSize, cacheBudget)
        self.sleep = sleep
    }

    /// Total size of the asset, from the `Content-Range` of a one-byte probe when not yet known.
    public func contentLength() async throws -> Int64 {
        if let knownLength { return knownLength }
        _ = try await fetch(first: 0, last: 0)
        guard let knownLength else { throw RangeFetchError.invalidResponse("The server did not report the file size.") }
        return knownLength
    }

    /// Bytes `[offset, offset + length)`, clamped to the end of the asset.
    public func read(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        var out = Data()
        var position = offset
        let end = offset + Int64(length)
        while position < end {
            try Task.checkCancellation()
            if let knownLength, position >= knownLength { break }
            let index = position / Int64(chunkSize)
            let chunk = try await chunk(index)
            let chunkStart = index * Int64(chunkSize)
            let from = Int(position - chunkStart)
            guard from < chunk.count else { break }
            let to = min(chunk.count, Int(end - chunkStart))
            out.append(chunk.subdata(in: from..<to))
            position = chunkStart + Int64(to)
            if chunk.count < chunkSize { break }   // the last chunk of the asset
        }
        return out
    }

    /// Bytes held in the cache (a test hook for the budget).
    public var cachedByteCount: Int { cachedBytes }

    private func chunk(_ index: Int64) async throws -> Data {
        if let hit = chunks[index] {
            recency.removeAll { $0 == index }
            recency.append(index)
            return hit
        }
        let data = try await fetchChunk(index)
        store(data, at: index)
        return data
    }

    private func store(_ data: Data, at index: Int64) {
        chunks[index] = data
        recency.append(index)
        cachedBytes += data.count
        while cachedBytes > cacheBudget, recency.count > 1 {
            let evicted = recency.removeFirst()
            cachedBytes -= chunks.removeValue(forKey: evicted)?.count ?? 0
        }
    }

    private func fetchChunk(_ index: Int64) async throws -> Data {
        let first = index * Int64(chunkSize)
        var last = first + Int64(chunkSize) - 1
        if let knownLength { last = min(last, knownLength - 1) }
        return try await fetch(first: first, last: last)
    }

    /// One validated range, with bounded retry and one canonical-URL refresh.
    private func fetch(first: Int64, last: Int64) async throws -> Data {
        var attempt = 1
        var refreshed = false
        while true {
            try Task.checkCancellation()
            do {
                return try await requestRange(first: first, last: last)
            } catch let failure as RangeAttemptFailure {
                if failure.expiredURL, !refreshed {
                    // The signed redirect target expired: go back to the canonical release URL.
                    refreshed = true
                    resolvedURL = nil
                    refreshCount += 1
                    continue
                }
                guard failure.error.isRetryable, attempt < policy.maxAttempts else { throw failure.error }
                try await sleep(policy.delay(afterAttempt: attempt, retryAfter: failure.retryAfter))
                attempt += 1
            }
        }
    }

    private struct RangeAttemptFailure: Error {
        let error: RangeFetchError
        var retryAfter: TimeInterval?
        var expiredURL = false
    }

    private func requestRange(first: Int64, last: Int64) async throws -> Data {
        var request = URLRequest(url: resolvedURL ?? url)
        request.setValue("bytes=\(first)-\(last)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 20
        requestCount += 1
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            let transient: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                                                 .dataNotAllowed, .secureConnectionFailed]
            throw RangeAttemptFailure(error: transient.contains(error.code)
                ? .retryable(error.localizedDescription) : .permanent(error.localizedDescription))
        }
        if let final = response.url, final != url { resolvedURL = final }
        switch response.statusCode {
        case 206:
            return try validatePartial(data, response: response, first: first, last: last)
        case 200:
            throw RangeAttemptFailure(error: .invalidResponse("The server ignored the byte range (HTTP 200)."))
        case 416:
            // Past the end of the asset: nothing there.
            if let total = ContentRange.unsatisfiedTotal(response.value(forHTTPHeaderField: "Content-Range")) {
                knownLength = total
                return Data()
            }
            throw RangeAttemptFailure(error: .permanent("The requested range is not satisfiable (HTTP 416)."))
        case 403, 410:
            throw RangeAttemptFailure(error: .permanent("The release asset URL is no longer valid (HTTP \(response.statusCode))."),
                                      expiredURL: true)
        case 408, 429, 500...599:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw RangeAttemptFailure(error: .retryable("The release is temporarily unavailable (HTTP \(response.statusCode))."),
                                      retryAfter: retryAfter)
        default:
            throw RangeAttemptFailure(error: .permanent("The release asset is unavailable (HTTP \(response.statusCode))."))
        }
    }

    private func validatePartial(_ data: Data, response: HTTPURLResponse, first: Int64, last: Int64) throws -> Data {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              let range = ContentRange(header: header) else {
            throw RangeAttemptFailure(error: .invalidResponse("Partial content without a valid Content-Range."))
        }
        // Fewer bytes than asked for is fine only at the end of the asset.
        let endOfAsset = range.total.map { range.last == $0 - 1 } ?? false
        guard range.first == first, range.last == last || (range.last < last && endOfAsset) else {
            throw RangeAttemptFailure(error: .invalidResponse(
                "Content-Range \(range.first)-\(range.last) does not match the request \(first)-\(last)."))
        }
        guard Int64(data.count) == range.last - range.first + 1 else {
            throw RangeAttemptFailure(error: .invalidResponse("The body length does not match its Content-Range."))
        }
        if let total = range.total {
            if let knownLength, knownLength != total {
                throw RangeAttemptFailure(error: .invalidResponse("The asset size changed between requests."))
            }
            knownLength = total
        }
        return data
    }
}

extension ContentRange {
    /// `Content-Range: bytes */total` on a 416.
    static func unsatisfiedTotal(_ header: String?) -> Int64? {
        guard let header else { return nil }
        let parts = header.split(separator: "/")
        guard parts.count == 2, parts[0].lowercased().hasPrefix("bytes") else { return nil }
        return Int64(parts[1])
    }
}
