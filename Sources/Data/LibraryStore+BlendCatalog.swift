import Foundation
import GRDB

public enum BlendCatalogError: Error, Equatable {
    case unknownTrack(String)
    case illegalTransition(from: BlendCatalogState, to: BlendCatalogState)
    case missingFacts(String)
}

extension LibraryStore {
    /// Inserts the pack's tracks and supplied plans at their final states. Idempotent; the v35
    /// migration calls it so a fresh install already holds the catalog (no download, no model).
    static func seedStarterCatalog(_ db: Database, pack: StarterBlendPack = .v1, now: Date = Date()) throws {
        // The release carries no key analysis, so starter rows keep `camelotKey` nil and are never
        // admitted to *new* edges until a key is stored; their 30 supplied plans are unaffected.
        var blendTraits: [String: (genre: String, subgenre: String)] = [:]
        for blend in StarterBlendCatalog.blends {
            for id in blend.trackIDs { blendTraits[id] = (blend.genre, blend.subgenre) }
        }
        for facts in StarterBlendRuntimeData.tracks {
            let record = BlendCatalogTrack(
                catalogKey: BlendCatalogTrack.key(pack: pack, trackID: facts.id), packTag: pack.releaseTag,
                state: facts.isBlendReady ? .edgePlanned : .unindexed, durationSeconds: facts.durationSeconds,
                bpm: facts.bpm, beatPeriod: facts.beatPeriod, beatPhase: facts.beatPhase, rmsDB: facts.rmsDB,
                updatedAt: now, genre: blendTraits[facts.id]?.genre, subgenre: blendTraits[facts.id]?.subgenre,
                camelotKey: nil, sourceURL: pack.assetURL(trackID: facts.id).absoluteString,
                analysisVersion: pack.releaseTag)
            try record.save(db)
        }
        for plan in StarterBlendRuntimeData.edges {
            try BlendCatalogEdge(fromKey: BlendCatalogTrack.key(pack: pack, trackID: plan.outgoingTrackID),
                                 toKey: BlendCatalogTrack.key(pack: pack, trackID: plan.incomingTrackID),
                                 packTag: pack.releaseTag, planJSON: JSONEncoder().encode(plan)).save(db)
        }
    }

    /// Catalog tracks at or beyond `state`: the only ones a blend may select.
    public func blendCatalogTracks(atLeast state: BlendCatalogState = .blendEligible,
                                   packTag: String? = nil) throws -> [BlendCatalogTrack] {
        try dbQueue.read { db in
            var request = BlendCatalogTrack.order(Column("catalogKey"))
            if let packTag { request = request.filter(Column("packTag") == packTag) }
            return try request.fetchAll(db).filter { $0.state >= state }
        }
    }

    public func blendCatalogTrack(key: String) throws -> BlendCatalogTrack? {
        try dbQueue.read { try BlendCatalogTrack.fetchOne($0, key: key) }
    }

    /// Adds a track at `.unindexed`, keeping any state it already reached.
    public func registerBlendCatalogTrack(key: String, packTag: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            guard try BlendCatalogTrack.fetchOne(db, key: key) == nil else { return }
            try BlendCatalogTrack(catalogKey: key, packTag: packTag, state: .unindexed, durationSeconds: nil,
                                  bpm: nil, beatPeriod: nil, beatPhase: nil, rmsDB: nil, updatedAt: date).insert(db)
        }
    }

    /// `unindexed → blendEligible`, only with complete, valid facts.
    public func markBlendEligible(key: String, facts: StarterTrackFacts, traits: BlendTraits,
                                  sourceURL: String? = nil, analysisVersion: String? = nil,
                                  at date: Date = Date()) throws {
        guard facts.isBlendReady, traits.isValid else { throw BlendCatalogError.missingFacts(key) }
        try dbQueue.write { db in
            guard var row = try BlendCatalogTrack.fetchOne(db, key: key) else { throw BlendCatalogError.unknownTrack(key) }
            guard row.state.canAdvance(to: .blendEligible) else {
                throw BlendCatalogError.illegalTransition(from: row.state, to: .blendEligible)
            }
            row.state = .blendEligible
            row.durationSeconds = facts.durationSeconds; row.bpm = facts.bpm; row.beatPeriod = facts.beatPeriod
            row.beatPhase = facts.beatPhase; row.rmsDB = facts.rmsDB; row.updatedAt = date
            row.genre = traits.genre; row.subgenre = traits.subgenre; row.camelotKey = traits.camelotKey.uppercased()
            row.sourceURL = sourceURL ?? row.sourceURL; row.analysisVersion = analysisVersion ?? row.analysisVersion
            try row.update(db)
        }
    }

    /// Stores a concrete plan for `from → to`; both ends must be blend-eligible, and each moves to
    /// `edgePlanned`. Replacing an edge's plan keeps one row per pair.
    public func recordBlendEdgePlan(_ plan: StarterEdgePlan, from fromKey: String, to toKey: String,
                                    packTag: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            for key in [fromKey, toKey] {
                guard var row = try BlendCatalogTrack.fetchOne(db, key: key) else { throw BlendCatalogError.unknownTrack(key) }
                if row.state == .unindexed { throw BlendCatalogError.illegalTransition(from: .unindexed, to: .edgePlanned) }
                if row.state == .blendEligible { row.state = .edgePlanned; row.updatedAt = date; try row.update(db) }
            }
            try BlendCatalogEdge(fromKey: fromKey, toKey: toKey, packTag: packTag,
                                 planJSON: JSONEncoder().encode(plan)).save(db)
        }
    }

    public func blendCatalogEdgePlan(from fromKey: String, to toKey: String) throws -> StarterEdgePlan? {
        try dbQueue.read { db in
            try BlendCatalogEdge.filter(Column("fromKey") == fromKey && Column("toKey") == toKey).fetchOne(db)?.plan
        }
    }
}
