import Foundation

/// Blend results for the Find tab: saved blends and starter blends matching a
/// query. Pure so the matching/ordering contract is testable without SwiftUI;
/// an empty or whitespace query deterministically yields no results.
public enum FindBlendSearch {
    public enum Result: Identifiable, Sendable, Equatable {
        case saved(BlendDocument)
        case starter(StarterBlend)

        public var id: String {
            switch self {
            case .saved(let blend): "saved.\(blend.id.uuidString)"
            case .starter(let blend): "starter.\(blend.id)"
            }
        }
    }

    public static func results(query: String, saved: [BlendDocument],
                               starters: [StarterBlend] = StarterBlendCatalog.blends) -> [Result] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        func hit(_ text: String) -> Bool {
            text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let savedHits = saved.filter { hit($0.title) }.map(Result.saved)
        let starterHits = starters.filter { hit($0.title) || hit($0.summary) }.map(Result.starter)
        return savedHits + starterHits
    }
}
