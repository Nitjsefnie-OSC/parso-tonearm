# Starter blends: immediate fresh-install readiness

## Decision

A starter blend must work on the first launch without account setup, model
downloads, library indexing, a Jamendo client ID, or a network connection.
The app will therefore ship a versioned **Starter Blend Pack** containing the
exact local audio assets used by every advertised starter blend. A remote
Jamendo lookup may refresh catalogue information for ordinary discovery, but
must never be a prerequisite for starting a starter blend.

This is intentionally not a cache-warming project. The current implementation
has only remote track identities at install time. Remote, uncached assets are
correctly denied Smart Blend admission because their duration, sample rate,
channel count, and bytes have not been established. A fresh-install promise
requires those bytes to be present in the app bundle.

## Definition of ready

"Ready" means all of the following are true for a selected starter blend:

- every advertised track resolves to the exact bundled bytes;
- each asset has verified duration, sample rate, channel count, container, and
  SHA-256 identity;
- all adjacent edges have validated transition analysis and a concrete plan;
- the queue is marked as a starter blend/mix before playback starts, so it is
  routed through MixDecks regardless of the global "use everywhere" preference;
- no edge is presented as planned until it has passed admission and plan
  validation.

It does **not** promise zero CPU work: MixDecks still decodes the current
local file into its bounded PCM working set. The performance target is audible
playback within one second on the supported-device baseline, with no network
activity. Missing/corrupt bundled content is a release-blocking error, not a
fallback to a different remote track.

## Pack format and ownership

1. Replace the Jamendo-only catalog entries with a `StarterBlendManifest`.
   It names a pack version, local resource path, source attribution/license,
   content hash, technical metadata, stable occurrence ID, and each requested
   edge style.
2. Add the licensed, immutable audio files and manifest as application
   resources. Keep the source-license evidence and attribution in-repository;
   verify redistribution rights and App Store package-size impact before adding
   any bytes. If the present Jamendo selections cannot be redistributed in the
   app, commission or select replacement CC-compatible assets rather than
   silently reverting to streamed playback.
3. Generate an analysis sidecar from those exact files in a reproducible build
   tool. It contains the analysis/plan inputs and the manifest hash it was
   generated against. At runtime, reject a sidecar whose asset hash differs.
4. Add `StarterBlendPackValidator`, run at app bootstrap and in release CI. It
   verifies resource existence, hashes, decoder capabilities, duration/sample
   metadata, all track counts, and every edge before Listen calls a card ready.

## Playback changes

1. Replace `StarterBlendPlayback.fetch` with a pack resolver. Card states become
   `validating`, `ready`, `starting`, and `unavailable(reason)`; the entire
   catalog may be validated concurrently at launch, but no card waits on
   network, model, or database work.
2. Build `TrackRow` and `Asset` values from the local resources. They must use a
   stable starter source identity and bundled/local `MixTrackSource`, never the
   remote Jamendo URL path.
3. Introduce a `QueueSource.starterBlend` (or an equivalent explicit mix
   source) that carries the manifest plan and stable occurrence IDs. Update
   `AppState` to use it when it invokes `AudioPlayer.play`. This makes starter
   blends opt into MixDecks even when Smart Transitions is disabled globally.
4. Teach `MixTrackLoader`/`BlendPlanCache` to consume the validated sidecar for
   a bundled asset after checking its hash. It may recompute analysis as a
   defensive fallback during development, but a release build treats a missing
   or invalid sidecar as pack failure rather than showing a claimed-ready blend.
5. Preflight all edges before enabling Play. For a ready blend, insert the
   concrete plans into `BlendPlanCache` before `AudioPlayer.play`; warm the
   first track's local decode on card selection. The transition card and queue
   consequently have a real plan from their first render.
6. If validation fails, the card is unavailable with an actionable explanation.
   Do not label an AVPlayer sequential queue as a starter *smart* blend. A
   deliberate "play as playlist" action may be offered separately.

## Delivery sequence

### 1. Asset and release gate

- Select/freeze the six blend asset sets and licenses.
- Create the manifest generator, hash/metadata validator, and CI resource-size
  budget.
- Add a build/release check that fails if any packaged blend has an invalid
  decoder, missing analysis, incomplete edge set, or unapproved license.

### 2. Local resolver and routing

- Implement the bundled resolver and its state model.
- Add the explicit starter queue source and stable occurrence mapping.
- Route ready starter requests through MixDecks and preserve existing normal
  playback for non-starter remote tracks.

### 3. Precomputation and user truth

- Build/verify sidecars and prepopulate `BlendPlanCache` from the pack.
- Surface validation/start progress only while the pack is genuinely not ready.
- Make the Listen card, Now Playing transition card, and Up Next rows report
  the same actual readiness and failure reason.

### 4. Verification and rollout

- Unit-test manifest integrity, tamper/hash rejection, no-network resolution,
  plan-cache population, and mix routing.
- Add a cold-install UI/production regression with networking disabled: select
  every starter blend, begin playback, and assert all edges have concrete
  plans—never `Smart blend unavailable` or `Not planned yet`.
- On devices, test a freshly installed release build in airplane mode, first
  launch after device restart, background/foreground, route changes, and low
  storage/memory conditions. Record the device, build, and measured
  time-to-audible result under the QA workflow.

## Non-goals

- Downloading the whole pack after installation and calling it immediate.
- Treating remote metadata or a cached URL as proof that source bytes are
  blendable.
- Advertising a fallback crossfade/sequential queue as the curated smart
  blend experience.
