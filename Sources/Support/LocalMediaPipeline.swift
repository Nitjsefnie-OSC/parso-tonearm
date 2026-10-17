import Foundation
import ImageIO
import OSLog
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Diagnostics

/// Privacy-safe, opt-in diagnostics for the local-playback path. Events carry a
/// stage, an opaque per-load ID, a monotonic timestamp, a bounded resident-memory
/// sample and numeric values only — never paths, names, tags, bookmarks or bytes.
/// Enabled in DEBUG builds or via the `localPlaybackDiagnostics` user default.
public final class LocalPlaybackDiagnostics: @unchecked Sendable {
    public enum Stage: String, Sendable {
        case resolveStart, resolveEnd, accessAcquired, accessDenied, accessReleased
        case itemBuilt, itemStatus, playerReplaced, itemDisposed
        case metadataStart, metadataEnd, metadataError
        case artworkDecodeStart, artworkDecodeEnd, artworkRejected
        case nowPlayingAppear, nowPlayingDisappear, artworkRequest
        case cancelled, memoryWarning
    }

    public struct Event: Equatable, Sendable {
        public let stage: Stage
        public let loadID: UInt64
        public let uptimeNanos: UInt64
        public let residentMegabytes: Int?
        public let values: [String: Int]
    }

    public static let shared = LocalPlaybackDiagnostics()

    private static let signposter = OSSignposter(subsystem: "guru.parso.tonearm", category: "LocalPlayback")
    private static let log = Logger(subsystem: "guru.parso.tonearm", category: "LocalPlayback")

    private let lock = NSLock()
    private var enabledOverride: Bool?
    private var nextID: UInt64 = 0
    private var sink: (@Sendable (Event) -> Void)?
    private let clock: @Sendable () -> UInt64
    private let memorySampler: @Sendable () -> Int?

    public init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                memorySampler: @escaping @Sendable () -> Int? = LocalPlaybackDiagnostics.residentMegabytes) {
        self.clock = clock
        self.memorySampler = memorySampler
    }

    public var isEnabled: Bool {
        get {
            lock.withLock {
                if let enabledOverride { return enabledOverride }
                #if DEBUG
                return true
                #else
                return UserDefaults.standard.bool(forKey: "localPlaybackDiagnostics")
                #endif
            }
        }
        set { lock.withLock { enabledOverride = newValue } }
    }

    public func setSink(_ sink: (@Sendable (Event) -> Void)?) { lock.withLock { self.sink = sink } }

    /// Opaque, process-local ID tying together the stages of one load.
    public func makeLoadID() -> UInt64 { lock.withLock { nextID += 1; return nextID } }

    public func record(_ stage: Stage, loadID: UInt64, values: [String: Int] = [:]) {
        guard isEnabled else { return }
        let event = Event(stage: stage, loadID: loadID, uptimeNanos: clock(),
                          residentMegabytes: memorySampler(), values: values)
        let sink = lock.withLock { self.sink }
        sink?(event)
        let id = Self.signposter.makeSignpostID()
        Self.signposter.emitEvent("stage", id: id,
                                  "\(stage.rawValue, privacy: .public) load=\(loadID, privacy: .public) rss=\(event.residentMegabytes ?? -1, privacy: .public)MB")
        Self.log.notice("stage=\(stage.rawValue, privacy: .public) load=\(loadID, privacy: .public) rssMB=\(event.residentMegabytes ?? -1, privacy: .public) values=\(values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","), privacy: .public)")
    }

    /// Physical footprint of this process in whole megabytes, where available.
    @Sendable public static func residentMegabytes() -> Int? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / (1024 * 1024))
        #else
        return nil
        #endif
    }
}

// MARK: - Bounded embedded-artwork decode

/// Hard budgets for embedded cover art. Anything over budget is rejected and the
/// normal placeholder is shown; audio playback is never affected.
public enum LocalArtworkLimits {
    /// Longest side of the stored thumbnail, in pixels (covers Now Playing on
    /// iPhone and the Watch; 1024 × 1024 × 4 B ≈ 4 MiB decoded at most).
    public static let maxThumbnailPixel = 1024
    /// Embedded cover bytes accepted for decoding.
    public static let maxEncodedBytes = 16 * 1024 * 1024
    /// Source pixel budget; ImageIO decodes only the thumbnail, but absurd
    /// declared dimensions are treated as malformed/hostile.
    public static let maxSourcePixels = 64 * 1024 * 1024
}

public struct DownsampledArtwork: @unchecked Sendable {
    public let image: CGImage
    public let sourceWidth: Int
    public let sourceHeight: Int
}

public enum EmbeddedArtworkDownsampler {
    /// Decodes at most `maxPixel` on the longest side without ever creating the
    /// full-resolution bitmap. Returns nil for malformed or over-budget data.
    public static func downsample(_ data: Data,
                                  maxPixel: Int = LocalArtworkLimits.maxThumbnailPixel,
                                  maxEncodedBytes: Int = LocalArtworkLimits.maxEncodedBytes,
                                  maxSourcePixels: Int = LocalArtworkLimits.maxSourcePixels) -> DownsampledArtwork? {
        guard !data.isEmpty, data.count <= maxEncodedBytes else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxSourcePixels else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return DownsampledArtwork(image: thumb, sourceWidth: width, sourceHeight: height)
    }
}

// MARK: - Single-flight coordination

/// Coalesces concurrent requests for the same key into one cancellable task.
/// Each caller is a counted consumer; when the last one cancels, the shared task
/// is cancelled and dropped. A finished flight is removed so later requests rerun.
public actor SingleFlight<Value: Sendable> {
    private struct Flight {
        let id: Int
        let task: Task<Value?, Never>
        var consumers: Int
    }

    private var flights: [String: Flight] = [:]
    private var nextFlightID = 0

    public init() {}

    public var activeCount: Int { flights.count }

    public func value(for key: String, work: @escaping @Sendable () async -> Value?) async -> Value? {
        let flightID: Int
        let task: Task<Value?, Never>
        if var existing = flights[key] {
            existing.consumers += 1
            flights[key] = existing
            flightID = existing.id
            task = existing.task
        } else {
            nextFlightID += 1
            flightID = nextFlightID
            let id = flightID
            task = Task { [weak self] in
                let result = await work()
                await self?.finish(key: key, flightID: id)
                return result
            }
            flights[key] = Flight(id: flightID, task: task, consumers: 1)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(key: key, flightID: flightID) }
        }
    }

    /// Cancels the flight for `key` regardless of consumers (track replaced).
    public func cancel(key: String) {
        guard let flight = flights.removeValue(forKey: key) else { return }
        flight.task.cancel()
    }

    public func cancelAll() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }

    private func finish(key: String, flightID: Int) {
        if flights[key]?.id == flightID { flights[key] = nil }
    }

    private func leave(key: String, flightID: Int) {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.consumers -= 1
        if flight.consumers <= 0 {
            flights[key] = nil
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
    }
}
