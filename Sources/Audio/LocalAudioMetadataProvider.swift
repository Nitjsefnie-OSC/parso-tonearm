import Foundation

/// Technical facts about a local audio file, read from container headers only.
public struct LocalAudioTechnicalMetadata: Equatable, Codable, Sendable {
    public let durationSeconds: Double
    public let sampleRate: Int
    /// Actual channel count from the header; never defaulted to stereo.
    public let channelCount: Int
    public let frameCount: Int64
    public let isSeekable: Bool
}

/// Truthful state of the optional metadata probe. Playback never waits on it.
public enum LocalAudioMetadataOutcome: Equatable, Sendable {
    case checkingDetails
    case temporarilyInaccessible
    case unsupported
    case resourceDenied
    case available(LocalAudioTechnicalMetadata)
}

/// Identity of the bytes a cached value was derived from. Replacing or
/// modifying the file changes it and so invalidates the cache entry.
public struct LocalAudioSourceFingerprint: Equatable, Codable, Sendable {
    public let size: Int64
    public let modified: Double
    public let fileID: UInt64?

    static func read(_ url: URL) -> LocalAudioSourceFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let date = attrs[.modificationDate] as? Date else { return nil }
        let id = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        return Self(size: size, modified: date.timeIntervalSince1970, fileID: id)
    }
}

/// Bounded FLAC header parser: reads at most a few KiB of metadata blocks
/// through a file handle. Never decodes PCM and never allocates by file size.
public enum FLACHeaderProbe {
    enum ProbeError: Error { case unsupported, malformed }

    static let maxMetadataBytes = 1 << 20
    static let maxBlocks = 256
    static let maxID3Bytes = 1 << 20
    static let maxChannels = 8
    static let maxDurationSeconds = 7.0 * 24 * 3600

    public static func probe(url: URL) throws -> LocalAudioTechnicalMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0

        func read(_ count: Int) throws -> Data {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw ProbeError.malformed
            }
            offset += UInt64(count)
            return data
        }

        var magic = try read(4)
        if magic.prefix(3) == Data("ID3".utf8) {
            let rest = try read(6)
            let sizeBytes = [UInt8](rest.suffix(4))
            guard sizeBytes.allSatisfy({ $0 < 0x80 }) else { throw ProbeError.malformed }
            let size = sizeBytes.reduce(0) { ($0 << 7) | Int($1) }
            guard size <= maxID3Bytes else { throw ProbeError.malformed }
            offset += UInt64(size)
            magic = try read(4)
        }
        guard magic == Data("fLaC".utf8) else { throw ProbeError.unsupported }

        var streamInfo: Data?
        var hasSeekTable = false
        var consumed = 0
        for index in 0..<maxBlocks {
            let header = [UInt8](try read(4))
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            consumed += 4 + length
            guard consumed <= maxMetadataBytes, type != 127 else { throw ProbeError.malformed }
            if index == 0 {
                guard type == 0, length == 34 else { throw ProbeError.malformed }
                streamInfo = try read(34)
            } else {
                if type == 0 { throw ProbeError.malformed }
                if type == 3 {
                    guard length % 18 == 0 else { throw ProbeError.malformed }
                    hasSeekTable = length > 0
                }
                offset += UInt64(length)
            }
            if isLast { break }
            if index == maxBlocks - 1 { throw ProbeError.malformed }
        }
        guard let info = streamInfo else { throw ProbeError.malformed }
        let b = [UInt8](info)
        let sampleRate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
        let channels = Int((b[12] >> 1) & 0x07) + 1
        var frames: Int64 = Int64(b[13] & 0x0F)
        for byte in b[14..<18] { frames = (frames << 8) | Int64(byte) }
        guard sampleRate > 0, channels <= maxChannels, frames > 0 else { throw ProbeError.malformed }
        let duration = Double(frames) / Double(sampleRate)
        guard duration.isFinite, duration > 0, duration <= maxDurationSeconds else { throw ProbeError.malformed }
        return LocalAudioTechnicalMetadata(durationSeconds: duration, sampleRate: sampleRate,
                                           channelCount: channels, frameCount: frames,
                                           isSeekable: hasSeekTable)
    }
}

/// Coalesced, fingerprint-validated, persisted metadata provider for imported
/// local media. Concurrent requests for one asset share a single probe.
public actor LocalAudioMetadataProvider {
    private struct Entry: Codable {
        var fingerprint: LocalAudioSourceFingerprint
        var metadata: LocalAudioTechnicalMetadata
    }

    private let resolver: LocalAssetResolver
    private let cacheURL: URL?
    private let probe: @Sendable (URL) throws -> LocalAudioTechnicalMetadata
    private var entries: [String: Entry]
    private var inFlight: [String: (generation: Int, task: Task<LocalAudioMetadataOutcome, Never>)] = [:]
    private var generations: [String: Int] = [:]
    public private(set) var probeCount = 0

    public init(resolver: LocalAssetResolver = .live, cacheURL: URL? = nil,
                probe: @escaping @Sendable (URL) throws -> LocalAudioTechnicalMetadata = FLACHeaderProbe.probe) {
        self.resolver = resolver
        self.cacheURL = cacheURL
        self.probe = probe
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    private static func key(_ asset: Asset) -> String {
        asset.id.map { "asset-\($0)" } ?? "track-\(asset.trackId)"
    }

    /// Non-blocking status: cached value, in-flight marker, or nil if never requested.
    public func status(for asset: Asset) -> LocalAudioMetadataOutcome? {
        let key = Self.key(asset)
        if inFlight[key] != nil { return .checkingDetails }
        return entries[key].map { .available($0.metadata) }
    }

    public func invalidate(_ asset: Asset) {
        let key = Self.key(asset)
        generations[key, default: 0] += 1
        inFlight[key]?.task.cancel()
        inFlight[key] = nil
        entries[key] = nil
        persist()
    }

    /// Returns the metadata, joining any probe already running for the asset.
    /// A cancelled caller gets `.checkingDetails` and never writes the cache.
    public func metadata(for asset: Asset) async -> LocalAudioMetadataOutcome {
        let key = Self.key(asset)
        let task: Task<LocalAudioMetadataOutcome, Never>
        if let running = inFlight[key] {
            task = running.task
        } else {
            let lease: ResolvedLocalAsset
            do { lease = try resolver.resolve(asset) } catch { return Self.outcome(for: error) }
            guard let fingerprint = LocalAudioSourceFingerprint.read(lease.url) else {
                lease.lease?.release()
                return .temporarilyInaccessible
            }
            if let cached = entries[key], cached.fingerprint == fingerprint {
                lease.lease?.release()
                return .available(cached.metadata)
            }
            let generation = (generations[key] ?? 0) + 1
            generations[key] = generation
            probeCount += 1
            let probe = self.probe
            task = Task.detached(priority: .utility) { [weak self] in
                defer { lease.lease?.release() }
                let result: Result<LocalAudioTechnicalMetadata, Error> = Result { try probe(lease.url) }
                let after = LocalAudioSourceFingerprint.read(lease.url)
                guard let self else { return .checkingDetails }
                return await self.finish(key: key, generation: generation, fingerprint: fingerprint,
                                         unchanged: after == fingerprint, result: result)
            }
            inFlight[key] = (generation, task)
        }
        let outcome = await task.value
        return Task.isCancelled ? .checkingDetails : outcome
    }

    private func finish(key: String, generation: Int, fingerprint: LocalAudioSourceFingerprint,
                        unchanged: Bool, result: Result<LocalAudioTechnicalMetadata, Error>) -> LocalAudioMetadataOutcome {
        let current = generations[key] == generation
        if current { inFlight[key] = nil }
        switch result {
        case .success(let value):
            guard unchanged else { return .temporarilyInaccessible }
            if current {
                entries[key] = Entry(fingerprint: fingerprint, metadata: value)
                persist()
            }
            return .available(value)
        case .failure(let error):
            let code = (error as NSError)
            if code.domain == NSCocoaErrorDomain,
               code.code == NSFileReadNoPermissionError { return .resourceDenied }
            if code.domain == NSCocoaErrorDomain,
               code.code == NSFileReadNoSuchFileError || code.code == NSFileNoSuchFileError {
                return .temporarilyInaccessible
            }
            return .unsupported
        }
    }

    private static func outcome(for failure: LocalMediaFailure) -> LocalAudioMetadataOutcome {
        switch failure {
        case .accessDenied: .resourceDenied
        case .unreadableMedia: .unsupported
        case .bookmarkUnresolvable, .fileMissing, .readinessTimeout: .temporarilyInaccessible
        }
    }

    private func persist() {
        guard let cacheURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

public extension LocalAudioTechnicalMetadata {
    /// Fills only missing/non-positive technical fields; descriptive tags are untouched.
    func fillingMissing(of track: Track) -> Track {
        var t = track
        if (t.durationSec ?? 0) <= 0 { t.durationSec = durationSeconds }
        if (t.sampleRate ?? 0) <= 0 { t.sampleRate = sampleRate }
        return t
    }
}
