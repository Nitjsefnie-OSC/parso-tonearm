import Foundation

/// User-presentable reason a local asset cannot be opened. Carries no paths.
public enum LocalMediaFailure: Error, Equatable, Sendable {
    case bookmarkUnresolvable
    case accessDenied
    case fileMissing
    case unreadableMedia
    case readinessTimeout

    public var logClass: String {
        switch self {
        case .bookmarkUnresolvable: "bookmark-unresolvable"
        case .accessDenied: "access-denied"
        case .fileMissing: "file-missing"
        case .unreadableMedia: "unreadable-media"
        case .readinessTimeout: "readiness-timeout"
        }
    }

    public var userMessage: String {
        switch self {
        case .unreadableMedia:
            String(localized: "File can't be played — reimport it", bundle: .module)
        case .readinessTimeout:
            String(localized: "File took too long to open — reimport or restore access", bundle: .module)
        default:
            String(localized: "File unavailable — reimport or restore access", bundle: .module)
        }
    }
}

/// A lifetime-bound security-scoped access grant. Every successful start is
/// balanced by exactly one stop: on `release()` or, failing that, on deinit.
public final class SecurityScopedAssetLease: @unchecked Sendable {
    private let stop: @Sendable () -> Void
    private let lock = NSLock()
    private var released = false

    init(stop: @escaping @Sendable () -> Void) { self.stop = stop }

    public func release() {
        lock.lock()
        let wasReleased = released
        released = true
        lock.unlock()
        if !wasReleased { stop() }
    }

    deinit { release() }
}

public struct ResolvedLocalAsset {
    public enum Backing: String, Sendable { case bookmark, relPath }
    public let url: URL
    public let backing: Backing
    public let bookmarkWasStale: Bool
    /// Non-nil for bookmark-backed URLs; keep it alive while the URL is in use.
    public let lease: SecurityScopedAssetLease?
}

/// The single resolver for local assets: bookmark, then app-owned relPath.
/// A URL is only returned after scoped access (when needed) has succeeded.
public struct LocalAssetResolver: Sendable {
    var resolveBookmark: @Sendable (Data) -> (url: URL, stale: Bool)?
    var startAccess: @Sendable (URL) -> Bool
    var stopAccess: @Sendable (URL) -> Void
    var fileExists: @Sendable (URL) -> Bool
    var managedBase: @Sendable () -> URL

    public static let live = LocalAssetResolver(
        resolveBookmark: { BookmarkVault.resolve($0) },
        startAccess: { $0.startAccessingSecurityScopedResource() },
        stopAccess: { $0.stopAccessingSecurityScopedResource() },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        managedBase: {
            (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }
    )

    public func resolve(_ asset: Asset) throws(LocalMediaFailure) -> ResolvedLocalAsset {
        var bookmarkFailure: LocalMediaFailure?
        if let bookmark = asset.bookmark {
            if let (url, stale) = resolveBookmark(bookmark) {
                guard startAccess(url) else { throw .accessDenied }
                let stop = stopAccess
                let lease = SecurityScopedAssetLease { stop(url) }
                guard fileExists(url) else {
                    lease.release()
                    throw .fileMissing
                }
                return ResolvedLocalAsset(url: url, backing: .bookmark, bookmarkWasStale: stale, lease: lease)
            }
            bookmarkFailure = .bookmarkUnresolvable
        }
        if let rel = asset.relPath {
            let url = managedBase().appendingPathComponent(rel)
            guard fileExists(url) else { throw .fileMissing }
            return ResolvedLocalAsset(url: url, backing: .relPath, bookmarkWasStale: false, lease: nil)
        }
        throw bookmarkFailure ?? .fileMissing
    }
}
