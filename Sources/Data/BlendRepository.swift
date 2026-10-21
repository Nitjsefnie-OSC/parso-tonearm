import Foundation

/// File-backed store of saved `BlendDocument`s. An actor, so concurrent saves
/// and removals are serialised; every write is atomic and the in-memory state
/// is only updated after the write succeeded, so a failure cannot leave a
/// duplicate or half-written entry behind.
public actor BlendRepository {
    public enum LoadIssue: Sendable, Equatable {
        /// The file could not be decoded; it was moved aside, not deleted.
        case malformedQuarantined(String)
        /// Written by a newer app; left untouched and not editable here.
        case newerSchema(Int)
        case legacyMigrated(Int)
    }

    public enum RepositoryError: Error, Equatable {
        case writeFailed(String)
        case readOnly
    }

    public struct Snapshot: Sendable, Equatable {
        public var blends: [BlendDocument]
        public var issues: [LoadIssue]
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var blends: [BlendDocument]
    }
    private struct VersionProbe: Codable { var schemaVersion: Int? }
    /// Pre-versioned shape: title + ordered syncIDs only.
    private struct LegacyEnvelope: Codable {
        struct Item: Codable { var id: UUID?; var title: String; var trackSyncIDs: [String] }
        var blends: [Item]
    }

    private let url: URL
    private var blends: [BlendDocument] = []
    private var issues: [LoadIssue] = []
    private var loaded = false
    private var readOnly = false

    public init(url: URL) { self.url = url }

    public func load() -> Snapshot {
        if !loaded { performLoad(); loaded = true }
        return Snapshot(blends: sorted(), issues: issues)
    }

    public func blend(id: UUID) -> BlendDocument? {
        _ = load()
        return blends.first { $0.id == id }
    }

    public func isSaved(id: UUID) -> Bool { blend(id: id) != nil }

    /// Idempotent: saving a document whose id is already stored replaces it
    /// only when it is at least as new (generation), never duplicating.
    @discardableResult
    public func save(_ document: BlendDocument) throws -> BlendDocument {
        _ = load()
        guard !readOnly else { throw RepositoryError.readOnly }
        var next = blends
        if let i = next.firstIndex(where: { $0.id == document.id }) {
            if document.generation >= next[i].generation { next[i] = document }
            else { return next[i] }
        } else {
            next.append(document)
        }
        try write(next)
        blends = next
        return document
    }

    /// Removes only the document with this id; absent ids are a no-op.
    public func remove(id: UUID) throws {
        _ = load()
        guard !readOnly else { throw RepositoryError.readOnly }
        let next = blends.filter { $0.id != id }
        guard next.count != blends.count else { return }
        try write(next)
        blends = next
    }

    public func markPlayed(id: UUID, at date: Date = Date()) throws {
        guard let doc = blend(id: id) else { return }
        _ = try save(doc.markingPlayed(at: date))
    }

    private func sorted() -> [BlendDocument] {
        blends.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
    }

    private func write(_ docs: [BlendDocument]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: BlendDocument.currentSchemaVersion, blends: docs))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw RepositoryError.writeFailed(String(describing: error))
        }
    }

    private func performLoad() {
        guard let data = try? Data(contentsOf: url) else { return } // no file: empty, not an error
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            quarantine(); return
        }
        let version = probe.schemaVersion ?? 0
        if version > BlendDocument.currentSchemaVersion {
            issues.append(.newerSchema(version)); readOnly = true; return
        }
        if version >= 1 {
            if let env = try? decoder.decode(Envelope.self, from: data) { blends = env.blends }
            else { quarantine() }
            return
        }
        guard let legacy = try? decoder.decode(LegacyEnvelope.self, from: data) else { quarantine(); return }
        blends = legacy.blends.map { item in
            BlendDocument(id: item.id ?? UUID(), title: item.title, origin: .manualQueue,
                          occurrences: item.trackSyncIDs.map {
                              .init(source: .init(syncID: $0, title: item.title))
                          })
        }
        issues.append(.legacyMigrated(version))
        try? write(blends)
    }

    private func quarantine() {
        let aside = url.appendingPathExtension("malformed-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: aside)
        issues.append(.malformedQuarantined(aside.lastPathComponent))
    }
}
