# Non-Destructive Video Stabilization — Design

**Date:** 2026-06-26
**Status:** Approved, pre-implementation

## Summary

Add native, non-destructive video stabilization to PalmierPro. An offline analysis
pass estimates per-frame camera motion with Apple's Vision framework, a pure
smoothing stage turns that into per-frame *correction* transforms, and the existing
Core Image / Metal compositor applies the correction at render time — **no new media
is written**. This mirrors Premiere's Warp Stabilizer model: analyze once (cached),
re-tune smoothing instantly, never rewrite the clip.

The key enabling fact, confirmed in the code: the compositor already re-samples a
per-frame `CGAffineTransform` on every frame (`FrameRenderer.swift:86-92`,
`containsTweening = true`), so a transform that changes every frame is the normal
path, not a special case.

## Scope

**In scope (v1):** three stabilization modes sharing one pipeline.

| Mode | Transform class | Render application |
|---|---|---|
| Position | translation only | folds into existing affine — free |
| Position + Scale + Rotation (default) | similarity | folds into existing affine — free |
| Perspective | full homography | `CIPerspectiveTransform` on the CIImage — one new Core Image hook |

One analysis produces a per-frame homography; the three modes are derived by
constraining it. Switching mode or smoothness never re-analyzes.

**Out of scope (v1):**
- Mesh / subspace warp (per-region) and rolling-shutter correction. These need a
  mesh-warp compositor and are deferred.
- Stabilization on clips with `speed != 1.0` or reversed playback. The control is
  disabled for those clips in v1.
- Audio clips, text/image/Lottie clips (video only).

## Architecture

Three independently testable units plus a render hook and UI.

### 1. `StabilizationAnalyzer` (new, `Stabilization/`)

The only genuinely new heavy code. Walks a video asset's frames sequentially via
`AVAssetReader`, downscaled to a fixed analysis resolution (~540p long edge) for
speed, and runs `VNHomographicImageRegistrationRequest` on each consecutive frame
pair → a per-source-frame raw camera path (array of `matrix_float3x3` homographies,
in normalized coordinates so analysis resolution is irrelevant to application).

- Robustness: low-texture frames make homographic registration unstable. Fall back
  to `VNTranslationalImageRegistrationRequest` for a pair when the homography is
  degenerate / its residual is high, and clamp per-frame correction magnitude.
- Runs in a background `Task`, gated by a semaphore, reporting progress — a direct
  structural copy of `ProxyManager` (`Proxy/ProxyManager.swift`).
- Output cached as a **sidecar artifact per asset**, keyed by source signature
  (`ProxySignature.of(url)`), same staleness model as proxies. Stored at
  `media/stabilization/<assetId>.json`. Keeps `project.json` lean; re-tuning never
  touches it.

Analysis is per *source asset* (camera motion is intrinsic to the footage), cached
once and shared by every clip referencing that asset.

**Path convention (pipeline contract):** the sidecar stores **absolute cumulative**
transforms — `frames[i]` is the camera pose at source frame `i` relative to frame 0
(frame 0 = identity). The analyzer composes its consecutive-frame registrations into
this absolute path before storing; `PathSmoother` smooths the absolute path directly
(no accumulation in the smoother).

### 2. `PathSmoother` (new, pure value → fully unit-testable)

No I/O. Input: the raw per-frame path + a `smoothness` parameter + the clip's
visible source-frame window + mode. Output:
- per-frame **correction** transform = smoothed path − original path, and
- the **auto-crop zoom factor** = the minimum uniform scale that keeps the corrected
  frame covering the full render rect across the visible window (max over frames of
  the exposed-border zoom requirement).

Smoothing v1 = Gaussian low-pass over the camera path (window derived from
`smoothness`). The interface leaves room to swap in L1-optimal paths later without
touching callers.

### 3. `Stabilization` model (new, `Models/Stabilization.swift`)

```swift
enum StabMethod: String, Codable, Sendable { case position, similarity, perspective }

struct Stabilization: Codable, Sendable, Equatable {
    var method: StabMethod = .similarity
    var smoothness: Double = 0.5   // 0…1, drives smoothing window
    var cropToFit: Bool = true     // auto-zoom to hide exposed borders
    var enabled: Bool = true
}
```

Added to `Clip` as `var stabilization: Stabilization?` (+ `CodingKeys` entry,
`Models/Timeline.swift:101-118`). Only the cheap params live on the clip; the
expensive raw analysis lives in the sidecar. The applied correction is computed by
`PathSmoother` from (sidecar analysis + clip params) — cached in memory, recomputed
on param change.

### 4. Render hook (`Compositing/FrameRenderer.swift`)

In `composedLayer`, before the existing placement transform (line 86):
- Resolve the clip's stabilization correction for the current source frame (mapped
  from the clip-relative frame).
- **Similarity / position:** concatenate the correction `CGAffineTransform` (built
  around the image center, including the crop-to-fit zoom) into the `av` chain — zero
  extra Core Image work.
- **Perspective:** apply `CIPerspectiveTransform` with destination corners derived
  from the homography, before placement.

Stabilization is prepended to the *source* image, so the user's own
position/scale/rotation transform composes on top and stays fully independent.

### 5. `StabilizationManager` (new, `@MainActor @Observable`)

Mirrors `ProxyManager`: `analyze(clip)` / `analyzeAll`, progress (`completed`,
`total`, ETA), `cancel()`, sidecar read/write, staleness check. Background job with
semaphore gating. Lives alongside the editor like `ProxyManager`.

### 6. UI

- Clip-inspector **Stabilization** section (new extension/view): enable toggle, mode
  picker, smoothness slider, crop-to-fit toggle. All via `AppTheme` constants.
- Background analysis surfaced through a HUD reusing the `ProxyProgressHUD` pattern
  (`UI/ProxyProgressHUD.swift`).
- Re-tuning smoothness/mode/crop is live (recompute correction, rebuild engine);
  only first-time analysis shows the HUD.

## Data flow

```
source asset ──► StabilizationAnalyzer (Vision, background, cached sidecar)
                     │  raw per-frame homographies
                     ▼
clip params ──► PathSmoother (pure) ──► per-frame correction + crop zoom
                                              │
                                              ▼
                          FrameRenderer prepends correction → existing compositor
```

## Error handling

- Analysis failure (unreadable asset, Vision error) → clip stabilization marked
  failed, surfaced in inspector; render falls back to identity (clip renders
  un-stabilized). Never blocks playback.
- Stale sidecar (source signature mismatch) → treated as missing; re-analyze.
- Degenerate per-frame homography → translational fallback + magnitude clamp.
- Missing sidecar at render time → identity correction (no crash, no stall).

## Testing

- `PathSmoother`: Swift Testing unit tests with synthetic jittery paths — smoothing
  reduces high-frequency motion, crop factor covers worst-case exposure, identity in
  / identity out. Pure, no fixtures.
- Crop-factor math: dedicated cases for pure-translation, pure-rotation, combined.
- `StabilizationAnalyzer`: one integration test on a tiny bundled fixture clip with
  known synthetic motion — asserts recovered path is close to ground truth.
- Sidecar round-trip + staleness: encode/decode and signature-mismatch invalidation.

## Files

**New:**
- `Models/Stabilization.swift`
- `Stabilization/StabilizationAnalyzer.swift`
- `Stabilization/PathSmoother.swift`
- `Stabilization/StabilizationManager.swift`
- `Stabilization/StabilizationSidecar.swift` (sidecar codec + paths)
- Inspector view for the stabilization section
- `Tests/…/PathSmootherTests.swift`, `StabilizationAnalyzerTests.swift`

**Modified:**
- `Models/Timeline.swift` — `Clip.stabilization` + `CodingKeys`
- `Compositing/FrameRenderer.swift` — correction hook in `composedLayer`
- Clip inspector container — mount the new section
- `Utilities/Constants.swift` — `stabilization` sidecar dir name

## Open implementation notes (resolved at plan time)

- Exact mapping from clip-relative frame → source frame for lookup (respect
  `trimStartFrame`).
- Homography → destination corners for `CIPerspectiveTransform`.
- Smoothness slider → Gaussian window size curve.
