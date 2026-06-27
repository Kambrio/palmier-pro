# Point Track stabilization engine

**Date:** 2026-06-28
**Branch:** `subject-tracking` (off `main`)

## Goal
A new `.points` engine: the user taps to place N points on an object; each point is tracked as a small
patch via `VNTrackObjectRequest`; per frame we fit the object's **similarity transform**
(translation + rotation + uniform scale) from the moving point cloud, smooth it, and stabilize — so
the object is held steady with rotation/scale lock, not just position. Reuses the existing
PathSmoother + compositor transform layer (same as Subject Lock), but with `method: .similarity`.

## Why this stack (researched, not invented)
Apple Vision has **no public multi-point tracker** (CoTracker/TAPIR/Track-On are research ML models,
not in Vision). The proven on-device technique is **multiple `VNTrackObjectRequest` patches** + a
closed-form similarity fit from the point cloud (the Mocha/After-Effects planar approach). On-device,
uses existing Vision, gives rotation+scale + outlier robustness.

## Components

### 1. Model (`Models/Stabilization.swift`)
- `StabEngine.points` (displayName "Point Track"); `isNative == true` (already, `!= .vidstab`).
- `struct PointsSeed: Codable, Equatable, Sendable { var frame: Int; var points: [CGPoint] /* normalized TOP-LEFT */ }`
  with a stable `seedKey` (frame + rounded points).
- `var pointsSeed: PointsSeed? = nil` on `Stabilization`; `decodeIfPresent ?? nil`.
- Reuse `smoothness` (lock strength), `subjectSmoothing` (Cinematic L1 / Organic Gaussian) and
  `cropToFit`. (Lock-axis does not apply to Point Track.)

### 2. `PointSetTracker.swift` (new, `Stabilization/`)
```swift
static func track(input: URL, seedFrame: Int, seedPointsTopLeft: [CGPoint],
                  progress: @escaping @Sendable (Double) -> Void)
    async throws -> (fps: Double, frames: [StabFrameTransform])
```
- For each seed point, build a small patch box (~6% of the min frame dimension, square) centered on
  the point → one `VNTrackObjectRequest`. Convert seed points TOP-LEFT → Vision bottom-left for boxes.
- Forward-track from `seedFrame`; backward-track `[0, seedFrame)` by buffering downscaled (≤720px long
  edge) deep-copied `CVPixelBuffer`s, capped at `maxBackwardFrames = 900` (beyond cap hold the seed
  transform). Same OOM/orientation discipline as `SubjectTracker` (load `preferredTransform` → pass
  `CGImagePropertyOrientation` to the Vision handlers; autoreleasepool per frame; `Task.yield`).
- Per frame: gather the patch centers that still track (confidence ≥ 0.3) → current points `Q`.
  Reference points `P` = the seed points. Fit the 2D similarity P→Q (below). Carry the last good
  transform if < 1 point tracks.
- Encode the fit as `StabFrameTransform(m: [a, -b, cx, b, a, cy, 0, 0, 1])` where `a = s·cosθ`,
  `b = s·sinθ`, and `(cx, cy)` = current centroid (normalized TOP-LEFT). This decomposes correctly in
  `PathSmoother` (tx=m[2]=cx, ty=m[5]=cy, rot=atan2(c,a)=θ, scale=hypot(a,c)=s).
- `frames.count == source frame count`.

### 3. Closed-form 2D similarity fit (no SVD needed)
Given matched reference `P_i` and current `Q_i` (same indices, only points that tracked this frame):
```
μP = mean(P);  μQ = mean(Q)
P' = P - μP;   Q' = Q - μQ
den = Σ (P'_i · P'_i)                         // Σ |P'|²
a   = Σ (P'_i · Q'_i) / den                   // = s·cosθ
b   = Σ (P'_i.x·Q'_i.y − P'_i.y·Q'_i.x) / den // = s·sinθ
```
- `scale s = hypot(a,b)`, `rotation θ = atan2(b,a)`, centroid translation = `μQ`.
- Need ≥ 2 tracked points for `a,b`; with exactly 1 point use translation only (`a=1,b=0`, centroid =
  that point); with 0 carry last.
- **Outlier rejection:** predict `Q̂_i = μQ + M·(P_i − μP)` with `M=[[a,-b],[b,a]]`; compute residuals
  `|Q̂_i − Q_i|`; if > 2 points, drop points with residual > 2.5× median and refit once.
- Guard `den > eps`; clamp `s` to a sane range (e.g. 0.2…5) and keep everything finite.

### 4. Sidecar — `PointSidecar` / `PointSidecarStore` (`StabilizationSidecar.swift`)
`{ version, sourceSig, seedKey, fps, frames }`, file `<assetId>.<seedHash>.points.json` (seedHash =
first 16 hex of SHA256 of seedKey). `read(assetId:baseDir:sourceSig:seedKey:)` requires all three.

### 5. `StabilizationManager`
- `enqueuePointsTrack(assetId:url:seed:)`, `runPointsTrack` (proxy when available; same gate/progress
  as subject), `hasPointsTrack(assetId:seed:)`, `reconcilePointsClips` (only `.points` clips with a
  seed). `corrections(for:)` `.points` branch: read points sidecar by the clip's `pointsSeed`, then
  `PathSmoother.corrections(raw:window:method:.similarity, engine: subjectSmoothing==.organic ? .smooth : .l1, smoothness:, cropToFit:)`.
  Cache key includes `pointsSeed.seedKey`.
- `pointMarks(for clip:, sourceFrame:) -> [CGPoint]?` (optional, for the live overlay): the tracked
  point positions for the frame, offset by the active correction + crop zoom into display space
  (mirror `subjectMark`).

### 6. UI
- Inspector engine picker: add `.points`. Selecting it (no seed) enters point-placing mode.
- A point-placing session on `EditorViewModel`: `struct PointPickSession { clipId; sourceFrame; points: [CGPoint] }`,
  `var pointPick: PointPickSession?`. `beginPointPick(clip:)` grabs the frame (no detection needed),
  shows the overlay. The overlay lets the user **tap to add** a dot, **drag** a dot to move, click a
  dot to remove (or a small ✕), with a "Track N points" confirm button and Esc cancel.
  `commitPointPick()` writes `pointsSeed` + `enqueuePointsTrack`.
- A `PointPickOverlay` (mirror `SubjectPickerOverlay` mapping: source-normalized via clip transform).
- Live `SubjectTrackOverlay` analog or extend it to draw the tracked points when engine `.points`.

## Tests
- Closed-form similarity fit: synthetic P with a known (s,θ,t) → recovered a,b,centroid within tol;
  outlier injected → rejected. Pure translation (1 point), identity (P==Q).
- `PointSetTracker` seeded: synthesize a clip with a rigid set of bright dots translating+rotating;
  assert recovered per-frame rot/scale/centroid follow the known motion before & after the seed.
- Decode: `pointsSeed` decodeIfPresent fallback + round-trip.
- `corrections(for:)` `.points` branch → finite bounded; nil without a seed.
- Full `swift test` green.

## Out of scope (v1)
- Freeform spline outline (dots approximate it; spline samples to points later).
- Perspective/planar (full homography) — similarity only.
- Per-point manual weighting.
