#if !os(watchOS)
import Foundation
import AVFoundation
import OSLog

private let mixDecksLog = Logger(subsystem: "guru.parso.tonearm", category: "MixDecks")

/// Smart transitions play on the mix decks (MixDeckPlayer), the app's one
/// planner and mixer for blends: the approved dj2 blends need both tracks on one
/// sample clock with a crossover in their path, which two AVPlayers can't give.
/// Everything else about the queue (index, Now Playing, persistence, Keep
/// Playing) stays in AudioPlayer. AVPlayer plays queues without smart
/// transitions, with the user's plain crossfade at most.
extension AudioPlayer: MixDeckHost {
    /// Whether the current queue plays on the mix decks: mixes, every queue when
    /// "Use for everything" is on, and auditions.
    var wantsMixDecks: Bool {
        guard !isAmbient else { return false }
        if plainRestoreAfterRecovery, isRestoring { return false }
        if auditionRequested || isMixQueue { return true }
        guard smartTransitionsEnabled else { return false }
        return UserDefaults.standard.bool(forKey: "smartTransitionsEverywhere")
    }

    /// A Build a Mix queue is the best DJ mix we can make: it always blends
    /// (double drop, bass swap, else a phrase cut), whatever the Smart
    /// transitions settings say. Other queues blend when those are on.
    var isMixQueue: Bool {
        if case .mix = queueSource { return true }
        return false
    }

    var mixDecksBlend: Bool { smartTransitionsEnabled || isMixQueue }

    /// Loads the current track onto the mix decks. False when the decks can't
    /// be created, and the caller plays it on AVPlayer instead.
    func loadCurrentOnMixDecks(row: TrackRow, autoplay: Bool) -> Bool {
        // An edge denied moments ago is not retried: that would re-enter the unsafe backend.
        if let denied = smartBlendDeniedTrackID {
            smartBlendDeniedTrackID = nil
            if denied == row.track.id { return false }
        }
        // Nothing is decoded (not even on queue restore, paused) unless the whole-track mixer is admitted.
        let admission = mixDecksAdmission(index: index, outgoing: nil)
        guard admission == .allowSmartBlend else {
            mixDecksLog.notice("smart blend not admitted for current track, playing normally: \(String(describing: admission), privacy: .public)")
            releaseSmartBlendReservation()
            smartBlendFallback = TransitionFallbackStatus(decision: admission)
            return false
        }
        smartBlendFallback = nil
        // Durable sentinel first: a kill during the decode or mixer start must be attributable.
        guard transitionSafety.enter(.startingCurrent) else {
            mixDecksLog.error("smart blend safety journal unavailable, playing normally")
            return false
        }
        if mixDecks == nil {
            do {
                mixDecks = try MixDeckPlayer(host: self)
            } catch {
                transitionSafety.resolve(.safeFallback)
                mixDecksLog.error("mix decks unavailable, playing on AVPlayer: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard let mixDecks else { transitionSafety.resolve(.safeFallback); return false }
        mixDecks.safety = transitionSafety
        cancelCrossfade(resetVolume: true)
        shutdownLoaders()
        dropPreloadedNext()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isOutgoingTransitionTailAudible = false
        deferredTransitionPlan = nil
        transitionPlan = nil

        mixDecks.volume = outputLevel
        mixDecks.blendsEnabled = mixDecksBlend
        currentTime = 0
        duration = row.track.durationSec ?? 0
        isPlaying = autoplay
        mixDecks.start(index: index, at: 0, autoplay: autoplay)
        updateNowPlaying()
        prefetchNext()
        if autoplay, let trackId = row.track.id {
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
        maybeExtendKeepPlayingQueue()
        return true
    }

    /// Resumes the decks, restarting the current track when it had played out.
    func resumeMixDecks(_ mixDecks: MixDeckPlayer) {
        if mixDecks.current == nil || mixDecks.hasReachedEnd {
            mixDecks.start(index: index, at: 0, autoplay: true)
        } else {
            mixDecks.resume()
        }
    }

    func stopMixDecks() {
        releaseSmartBlendReservation()
        guard let mixDecks else { return }
        mixDecks.stop()
        self.mixDecks = nil
        isOutgoingTransitionTailAudible = false
        deferredTransitionPlan = nil
        transitionPlan = nil
        transitionPrepState = .ready
    }

    // MARK: - MixDeckHost

    var mixDecksCurrentIndex: Int { index }

    func mixDecksUpcomingIndex(after current: Int) -> Int? {
        guard !queue.isEmpty, repeatMode != .one, !sleepAtEndOfTrack else { return nil }
        let next: Int
        if current < queue.count - 1 {
            next = current + 1
        } else if repeatMode == .all, queue.count > 1 {
            next = 0
        } else {
            return nil
        }
        // An unplayable or Wi-Fi-only next track isn't blended into; when the
        // current one ends, next() skips it as it would without the decks.
        guard let asset = queue[next].asset, asset.unsupportedReason == nil,
              playbackDecision(for: asset) != .skipWiFiOnly else { return nil }
        return next
    }

    func mixDecksEdge(from: Int, to: Int) -> MixDeckEdge {
        guard queue.indices.contains(from), queue.indices.contains(to) else { return .blend }
        if CrossfadeCurve.suppressesForGaplessAlbum(current: CrossfadeCurve.AlbumContinuity(row: queue[from]),
                                                    next: CrossfadeCurve.AlbumContinuity(row: queue[to])) {
            return .gapless
        }
        if case .mix(let mix) = queueSource,
           mix.transitionPlans.contains(where: {
               $0.fromTrackID == queue[from].track.id && $0.toTrackID == queue[to].track.id
                   && $0.style == .plainCrossfade
           }) {
            return .fade
        }
        return .blend
    }

    func mixDecksTrack(at index: Int) -> (trackID: Int64, source: MixTrackSource, bpm: Double?)? {
        guard queue.indices.contains(index), let id = queue[index].track.id,
              let asset = queue[index].asset, let source = mixTrackSource(for: asset) else { return nil }
        return (id, source, nil)
    }

    func mixDecksDidAdvance(to scheduledIndex: Int, trackID: Int64, duration trackDuration: Double) -> Int {
        // The queue may have been edited since the blend was scheduled: find the track again.
        let newIndex: Int
        if queue.indices.contains(scheduledIndex), queue[scheduledIndex].track.id == trackID {
            newIndex = scheduledIndex
        } else if let found = queue.indices.first(where: { $0 > index && queue[$0].track.id == trackID })
                    ?? queue.indices.first(where: { queue[$0].track.id == trackID }) {
            newIndex = found
        } else {
            return scheduledIndex
        }
        // A blend hands over while the outgoing track is still audible: keep showing A→B.
        if let plan = transitionPlan, plan.toTrackID == trackID, plan.style != .gapless {
            isOutgoingTransitionTailAudible = true
        }
        index = newIndex
        let row = queue[newIndex]
        duration = row.track.durationSec ?? trackDuration
        if let seconds = mixDecks?.currentSeconds { currentTime = seconds }
        if let trackId = row.track.id {
            recordKeepPlayingHistory(trackId)
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
        updateNowPlaying()
        prefetchNext()
        maybeExtendKeepPlayingQueue()
        return newIndex
    }

    func mixDecksDidReachEnd(trackID: Int64) {
        guard currentTrack?.track.id == trackID else { return }
        if sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            pause()
            return
        }
        next()
    }

    /// Capabilities of the queue row's source from the one authority; never DB duration/rate or a stereo default.
    func smartBlendCapabilities(at i: Int) -> AudioAssetCapabilities {
        let row = queue[i]
        let id = row.asset.map { "asset-\($0.id ?? $0.trackId)" } ?? "track-\(row.track.id ?? -1)"
        guard let asset = row.asset, let source = mixTrackSource(for: asset) else {
            return .unresolved(id, .unavailableSource)
        }
        switch source {
        case .remote:
            return audioCapabilities.capabilities(for: .remoteUncached(key: "remote-\(asset.trackId)"))
        case .file(let url, _, let securityScoped):
            let managed = asset.relPath.map { managedURL($0).path == url.path } ?? false
            if securityScoped || managed { return audioCapabilities.capabilities(for: .local(asset)) }
            return audioCapabilities.capabilities(for: .file(url, key: "cache-\(url.lastPathComponent)"))
        }
    }

    func releaseSmartBlendReservation() {
        smartBlendReservation?.release()
        smartBlendReservation = nil
    }

    func mixDecksAdmission(index target: Int, outgoing: Int?) -> TransitionAdmissionDecision {
        // A new request replaces any earlier reservation first, so duplicates never stack.
        releaseSmartBlendReservation()
        guard queue.indices.contains(target) else { return .gaplessFallback(reason: .unavailableSource) }
        audioCapabilities.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.mixDecks?.upcomingChanged() }
        }
        let incoming = smartBlendCapabilities(at: target)
        let outgoingCaps = outgoing.flatMap { queue.indices.contains($0) ? smartBlendCapabilities(at: $0) : nil }
        let decision = AudioAssetCapabilityService.decide(outgoing: outgoingCaps, incoming: incoming)
        guard decision == .allowSmartBlend else { return decision }
        guard let bytes = AudioAssetCapabilityService.reservationBytes(outgoing: outgoingCaps, incoming: incoming) else {
            return .gaplessFallback(reason: .unavailableMetadata)
        }
        switch resourceCoordinator.reserve(.blendPreparation, bytes: bytes) {
        case .success(let reservation):
            smartBlendReservation = reservation
            return .allowSmartBlend
        case .failure(let denial):
            switch denial {
            case .absoluteCap: return .gaplessFallback(reason: .decodedMemoryBudget)
            case .invalidRequest: return .gaplessFallback(reason: .unavailableMetadata)
            default: return .gaplessFallback(reason: .memoryPressure)
            }
        }
    }

    func mixDecksDenied(index deniedIndex: Int, decision: TransitionAdmissionDecision) {
        releaseSmartBlendReservation()
        smartBlendFallback = TransitionFallbackStatus(decision: decision)
        transitionPlan = nil
        transitionPrepState = .failed(smartBlendFallback?.message ?? "")
        // Per-edge only: the "Everywhere" preference is untouched.
        smartBlendDeniedTrackID = queue.indices.contains(deniedIndex) ? queue[deniedIndex].track.id : nil
        guard deniedIndex == index else {
            // Prepare the denied upcoming track on the normal player now, so the handoff
            // does not wait for next() to build it.
            preloadNextItem(allowingMixDecks: true)
            return
        }
        // The current track itself was denied: play it on AVPlayer, never skip it,
        // keeping its position and play state.
        let resume = isPlaying
        let position = mixDecks?.currentSeconds ?? currentTime
        stopMixDecks()
        loadCurrent(autoplay: resume)
        if position > 0.5 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            currentTime = position
        }
    }

    func mixDecksCouldNotPlay(index failedIndex: Int, reason: String) {
        let title = queue.indices.contains(failedIndex) ? queue[failedIndex].track.title : "?"
        // Diagnostics carry an opaque load ID only: no title, path, URL or error text.
        mixDecksLog.error("mix decks: skipping load \(UUID().uuidString.prefix(8), privacy: .public): playback error")
        releaseSmartBlendReservation()
        networkSkipMessage = String(localized: "Skipped \(title): \(reason)", bundle: .module)
        guard failedIndex == index else { return }
        next()
    }

    func mixDecksPosition(seconds: Double) {
        let previous = currentTime
        currentTime = seconds
        if abs(seconds - previous) >= 0.5 || seconds < previous {
            updateNowPlayingTime()
        }
        persistTick()
    }

    func mixDecksLoading(_ loading: Bool) {
        guard isStalled != loading else { return }
        isStalled = loading
        updateNowPlaying()
    }

    func mixDecksPublish(plan: TransitionPlan?, state: GridPrepState) {
        if isOutgoingTransitionTailAudible {
            deferredTransitionPlan = (plan, state)
            return
        }
        transitionPlan = plan
        transitionPrepState = state
    }

    func mixDecksOutgoingDidFinish() {
        endOutgoingTransitionTail()
    }

    /// The outgoing track is inaudible (or the transition was cancelled): B→C may show now.
    func endOutgoingTransitionTail() {
        let deferred = deferredTransitionPlan
        deferredTransitionPlan = nil
        guard isOutgoingTransitionTailAudible || deferred != nil else { return }
        isOutgoingTransitionTailAudible = false
        if let deferred {
            transitionPlan = deferred.plan
            transitionPrepState = deferred.state
        } else {
            transitionPlan = nil
        }
    }

    // MARK: - Sources

    /// Where the mix decks read an asset: the same choices as `buildItem`
    /// (Opus CAF, bundled, complete cache, stream, bookmark, managed file).
    func mixTrackSource(for asset: Asset) -> MixTrackSource? {
        if let opusString = asset.opusRemoteURL, let opusURL = URL(string: opusString) {
            let caf = AudioCache.cafURL(forRemoteOpus: opusURL)
            if FileManager.default.fileExists(atPath: caf.path) {
                return .file(caf, container: .caf, securityScoped: false)
            }
        }
        if asset.kind == .builtIn, let channelId = asset.relPath,
           let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channelId) {
            return .file(url, container: .auto, securityScoped: false)
        }
        if asset.kind == .remote, let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) {
            let container = remote.pathExtension.isEmpty
                ? MixTrackLoader.container(forMIME: remoteAudioMIMEType(for: remote)) : .auto
            if AudioCache.completeCacheExists(for: remote) {
                let cached = AudioCache.fileURL(for: AudioCache.key(for: remote))
                if FileManager.default.fileExists(atPath: cached.path) {
                    return .file(cached, container: container == .auto
                                 ? MixTrackLoader.container(forExtension: remote.pathExtension) : container,
                                 securityScoped: false)
                }
            }
            let cacheKey = asset.transientRemoteSupportsByteRanges ? AudioCache.key(for: remote) : nil
            return .remote(remote, headers: asset.transientRemoteHeaders, container: container, cacheKey: cacheKey)
        }
        if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark) {
            return .file(url, container: .auto, securityScoped: true)
        }
        if let rel = asset.relPath {
            return .file(managedURL(rel), container: .auto, securityScoped: false)
        }
        return nil
    }
}
#endif

extension AudioPlayer {
    /// The displayed edge for the playing track: A→B until A is inaudible, then B→C.
    public var transitionPresentation: TransitionPresentation {
        if isAmbient || queue.isEmpty { return .none }
        let hasNext = index + 1 < queue.count || repeatMode == .all
        return TransitionPresentation.make(plan: transitionPlan, preparation: transitionPrepState,
                                           hasNext: hasNext || isOutgoingTransitionTailAudible,
                                           position: currentTime,
                                           outgoingTail: isOutgoingTransitionTailAudible)
    }
}
