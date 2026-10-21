# Starter blends: immediate online readiness

## Decision

A starter blend must be selectable on the first launch without account setup,
model downloads, library indexing, or a Jamendo client ID. The app bundles a
small, versioned **Starter Blend Manifest Pack**: blend definitions, immutable
AAC release URLs, byte ranges, hashes, technical metadata, attribution, and
precomputed edge plans. Audio is hosted as immutable assets in a GitHub
Release (during the first implementation) rather than committed to the app.

This is intentionally not a cache-warming project. The current implementation
has only remote track identities at install time. Remote, uncached assets are
correctly denied Smart Blend admission because their duration, sample rate,
channel count, and bytes have not been established. The manifest supplies
verified facts and the playback engine must progressively fetch exact byte
ranges from its immutable release asset while playing.

## Definition of ready

"Ready" means all of the following are true for a selected starter blend:

- every advertised track resolves to a version-pinned release asset;
- each asset has a verified duration, sample rate, channel count, container,
  SHA-256 identity, and byte-range capability;
- all adjacent edges have validated transition analysis and a concrete plan;
- the queue is marked as a starter blend/mix before playback starts, so it is
  routed through MixDecks regardless of the global "use everywhere" preference;
- no edge is presented as planned until it has passed admission and plan
  validation.

It does **not** promise zero CPU or network work. The performance target is
audible playback after a small initial buffer (target: one second on the
supported-network baseline), while later ranges continue to arrive. Missing,
corrupt, non-range-capable, or hash-mismatched content is a release-blocking
error, not a fallback to a different remote track.

## Pack format and ownership

1. Replace the Jamendo-only catalog entries with a `StarterBlendManifest`.
   It names a release/pack version, immutable HTTPS asset URL, source
   attribution/license, content hash, technical metadata, stable occurrence
   ID, and each requested edge style.
2. Publish licensed AAC assets only as immutable GitHub Release assets. Keep
   the source-license evidence and attribution in-repository; verify explicit
   redistribution rights before publishing. If the present Jamendo selections
   cannot be redistributed, commission or select replacement CC-compatible
   assets rather than silently mirroring them.
3. Generate an analysis sidecar from those exact files in a reproducible build
   tool. It contains the analysis/plan inputs and the manifest hash it was
   generated against. At runtime, reject a sidecar whose asset hash differs.
4. Add `StarterBlendPackValidator`, run in release CI and at app bootstrap. It
   verifies signed manifest structure, release URL/version pinning, declared
   range support, hashes, decoder capabilities, duration/sample metadata, all
   track counts, and every edge before Listen calls a card ready.

### Reuse for authored and saved blends

The format is not starter-only. Every app-authored, curated blend is added to
the same source catalog, published as a new immutable AAC release tag, and
identified by `(releaseTag, assetSHA256, occurrenceID)` in its
`BlendDocument`. Saving and replaying one of those blends therefore resolves
the exact audio revision and its matching edge plans, not a mutable URL.

User-created documents remain durable today through `BlendRepository`. A
document that points at user-library or third-party-provider media retains its
existing stable source identity and re-resolves that media under its provider's
rules. The app must never upload a listener's private library audio to the
Tonearm GitHub release; only app-owned/CC0 curated packs use this publisher.

## Playback changes

1. Replace `StarterBlendPlayback.fetch` with a manifest resolver. Card states
   become `validating`, `ready`, `starting`, and `unavailable(reason)`; the
   bundled manifest validates at launch, but selection does not wait for model
   or database work.
2. Build `TrackRow` and `Asset` values from versioned release assets. They use a
   stable starter source identity, immutable URLs, expected hashes, and a
   byte-range-capable `MixTrackSource`, never the Jamendo API path.
3. Introduce a `QueueSource.starterBlend` (or an equivalent explicit mix
   source) that carries the manifest plan and stable occurrence IDs. Update
   `AppState` to use it when it invokes `AudioPlayer.play`. This makes starter
   blends opt into MixDecks even when Smart Transitions is disabled globally.
4. Add a range-backed AAC source to MixDecks. It downloads only the first
   decode buffer to start, retains a bounded ahead/behind window, honours
   cancellation and cellular policy, and fails an edge early if its next
   required ranges cannot meet the transition deadline. The current whole-file
   `MixTrackLoader` cannot meet this requirement and must not be relabelled as
   immediate streaming.
5. Teach `MixTrackLoader`/`BlendPlanCache` to consume the validated sidecar
   after hash verification. It may recompute analysis only in development; a
   release build treats a missing or invalid sidecar as pack failure rather
   than showing a claimed-ready blend.
6. Install concrete plans into `BlendPlanCache` before `AudioPlayer.play`.
   Buffer the opening track and the first transition window only; schedule later
   windows ahead of their edge deadlines. The transition card and queue
   consequently have a real plan from their first render.
6. If validation fails, the card is unavailable with an actionable explanation.
   Do not label an AVPlayer sequential queue as a starter *smart* blend. A
   deliberate "play as playlist" action may be offered separately.

## Streaming MixDeck migration

Production MixDecks currently require a full `PCMBuffer` and therefore download
and decode an entire remote track before `MixEngine.prepare`. Tonearm already
has the replacement realtime primitive: `BoundedDeckMixer` owns two
`BoundedDeckBuffer`s, has a shared sample clock, never performs I/O on the
render thread, rejects stale generations after seek/reuse, and delays an
overlap until the incoming deck has enough audio. It is covered by offline
tests but is not yet connected to `MixDeckOutput`.

1. Add an `HTTPRangeAACSource` actor. It owns URLSession requests, a
   content-addressed sparse on-disk cache, HTTP validators, cancellation, and
   an AAC frame/byte index generated with the release pack. Network work only
   writes verified bytes into that cache; it never runs in the render callback.
2. Add a decoder worker per active deck. It reads only verified local ranges,
   converts AAC to 44.1 kHz stereo PCM, and writes tagged chunks to the deck's
   `BoundedDeckBuffer`. A cache miss returns no frames, requests the needed
   range, and lets the existing buffer report a stall rather than fabricating
   silence or advancing the source clock.
3. Replace the `MixEngine` source node in `MixDeckOutput` with a source node
   that calls `BoundedDeckMixer.render`. Preserve the existing audio-thread
   rules: fixed scratch buffers, no allocation, no locks, no URLSession, and
   no object lifecycle work in the callback.
4. Port `MixDeckPlayer` incrementally behind a feature flag. The current track
   begins once its initial buffer floor is met; the incoming edge is scheduled
   only when its precomputed plan exists and its required range deadline is
   feasible. The mixer keeps the outgoing deck unattenuated when the incoming
   buffer is late, then reports the real delayed/fallback reason.
5. Keep planning separate from decoding. Pack sidecars supply the analysis and
   transition plans; they are hash-bound to the release asset. A mismatched
   sidecar or changed bytes disables that smart edge before it reaches the
   audio engine.
6. Add deterministic HTTP-range fixture tests for initial-buffer startup,
   slow ranges, 206/ETag validation, seek cancellation, stale-generation
   rejection, interrupted route/backgrounding, incoming-edge deadline misses,
   bounded resident memory, and no I/O/allocation on the render thread.

The release publisher must also emit the frame/byte index. Fast-start M4A is
acceptable only if the index can identify AAC sample boundaries without a
whole-file download; otherwise publish an indexed AAC-LC transport form. The
workflow must probe a newly uploaded release asset for `Accept-Ranges: bytes`
and a successful `206` response before recording it in a shipped manifest.

## Delivery sequence

### 1. Asset and release gate

- Select/freeze the six blend asset sets and licenses.
- Create an AAC transcode/release publisher, manifest generator, and
  hash/metadata validator.
- Add a build/release check that fails if any release asset has an invalid
  decoder, missing analysis, incomplete edge set, immutable-version mismatch,
  or unapproved license.

### 2. Local resolver and routing

- Implement the manifest resolver and its state model.
- Add the explicit starter queue source and stable occurrence mapping.
- Route ready starter requests through MixDecks and preserve existing normal
  playback for non-starter remote tracks.

### 3. Precomputation and user truth

- Build/verify sidecars and prepopulate `BlendPlanCache` from the manifest.
- Surface validation/start progress only while the pack is genuinely not ready.
- Make the Listen card, Now Playing transition card, and Up Next rows report
  the same actual readiness and failure reason.

### 4. Verification and rollout

- Unit-test manifest integrity, tamper/hash rejection, no-network resolution,
  plan-cache population, and mix routing.
- Add a cold-install UI/production regression with a range-capable HTTP fixture:
  select every starter blend, begin buffered playback, and assert all edges
  have concrete plans—never `Smart blend unavailable` or `Not planned yet`.
- On devices, test a freshly installed release build on Wi-Fi and cellular,
  first launch after device restart, background/foreground, route changes,
  interrupted downloads, and low storage/memory conditions. Record the device,
  build, and measured time-to-audible result under the QA workflow.

## Non-goals

- Downloading the whole pack before starting and calling it immediate.
- Treating a remote URL or manifest metadata as proof that live source bytes
  are blendable without range, hash, and deadline verification.
- Advertising a fallback crossfade/sequential queue as the curated smart
  blend experience.
