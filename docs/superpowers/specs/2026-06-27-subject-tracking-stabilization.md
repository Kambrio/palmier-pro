# Subject-Tracking Stabilization Engine

**Date:** 2026-06-27
**Branch:** `subject-tracking` (off `main`, which has the working baked vid.stab global engine)

## Goal
Add a `.subject` stabilization engine that keeps a tracked subject (person/face) steady in frame —
complementary to the global vid.stab engine (which removes whole-frame hand-shake). Reuses the
existing transform-layer: the subject's per-frame screen position is treated as the "camera path"
and flows through the SAME `PathSmoother` + `resolveStabByClip` + `FrameRenderer` as the native
engines. Only new code: a Vision-based `SubjectTracker`.

## Why it reuses everything
Stabilizing the subject = removing the jitter of the subject's screen position while keeping its slow
movement. That's exactly `correction = smoothed(path) − path` with `path` = subject center. So:
- `SubjectTracker` outputs one `StabFrameTransform` per frame with `tx = subjectCenterX`,
  `ty = subjectCenterY` (normalized, top-left origin), scale/rot identity.
- `corrections(for:)` for `.subject` runs `PathSmoother.corrections(method: .position, ...)` on it.
- `.subject.isNative == true` (it's not vid.stab) → already included in `resolveStabByClip` → renders
  through the compositor like L1/Smooth. Same correction sign that already works for global.

## Components

### 1. Model — `StabEngine.subject`
`Sources/PalmierPro/Models/Stabilization.swift`: add `case subject`, displayName "Subject Lock".
`isNative` already returns `self != .vidstab` → true for `.subject` (correct). No decoder change
needed (decodeIfPresent fallback unaffected).

### 2. `SubjectTracker.swift` (new, `Stabilization/`)
```
static func track(input: URL, progress:) async throws -> (fps: Double, frames: [StabFrameTransform])
```
- Decode frames via `AVAssetReader` (`kCVPixelFormatType_32BGRA`, `alwaysCopiesSampleData=false`),
  **autoreleasepool per frame** (OOM lesson), periodic `await Task.yield()`.
- Frame 0: detect the primary subject — `VNDetectHumanRectanglesRequest`; if none,
  `VNDetectFaceRectanglesRequest`. Pick the LARGEST box. If nothing detected on the whole clip,
  throw `Failure("no subject detected")`.
- Seed `VNTrackObjectRequest(detectedObjectObservation:)` with that box; run a single
  `VNSequenceRequestHandler` across frames → per-frame bounding box + confidence.
- On low confidence (e.g. < 0.3) or tracking loss, re-run detection on that frame to re-seed.
- Per frame, subject center: Vision boxes are normalized BOTTOM-LEFT origin → convert to top-left:
  `cx = box.midX`, `cy = 1 - box.midY`. Append `StabFrameTransform(m: [1,0,cx, 0,1,cy, 0,0,1])`.
  (Carry the last center forward on a dropped frame so the path stays continuous.)
- Return `(fps, frames)`; frames.count == source frame count.

### 3. Sidecar — `SubjectSidecar` (in `StabilizationSidecar.swift` or new)
`{ version, sourceSig, fps, frames }` stored at `<stab dir>/<assetId>.subject.json`, read requires
version + sourceSig match (mirror `StabilizationSidecar`). Keyed by source identity only (tracking
doesn't depend on smoothness — smoothing is render-time).

### 4. `StabilizationManager`
- A subject-track queue mirroring the analysis queue: `enqueueSubjectTrack(assetId:url:)`,
  `runSubjectTrack` → `SubjectTracker.track` → write `SubjectSidecar`; on done
  `editor.onPersistentStateChanged?()` + `editor.videoEngine?.refreshVisuals()`. Reuse
  `progressByAsset` for the HUD (or a `subjectProgress`).
- `hasSubjectTrack(assetId:)` → SubjectSidecar exists + sig matches.
- `corrections(for:)`: branch at the top — if `stab.engine == .subject`, read the SubjectSidecar,
  window `frames[trimStart ..< min(count, trimStart+consumed)]`, and return
  `PathSmoother.corrections(raw: windowed, method: .position, engine: .l1, smoothness: stab.smoothness,
  cropToFit: stab.cropToFit)`. (Translation-only L1 on the subject path: removes the subject's
  jitter, keeps its slow movement.) Else → existing native path.
- `reconcile…`: add subject clips to the on-rebuild reconcile (enqueue track if missing). Keep the
  existing native + vidstab reconciles; `.subject` clips skip Vision-global analysis and vidstab bake.
- `resolveStabByClip`: NO change needed — `.subject` is `isNative`, so it already iterates and calls
  `corrections(for:)`, which now returns the subject result.

### 5. Inspector
`InspectorView.swift` engine picker: `StabEngine.allCases` already includes `.subject`. On enabling
or selecting `.subject`, trigger `enqueueSubjectTrack` (not bake/analysis). Add `engineLabel(.subject)`
= "Subject Lock". Show track progress like the others.

## Tests
- `SubjectTrackerTests`: synthesize a clip with a moving bright rectangle on a textured bg
  (`TestClip`), track it, assert the recovered center path follows the rectangle's known motion
  (within tolerance) and is finite/bounded. Guard nothing (Vision is always available).
- `corrections(for:)` subject branch: smoke (a subject sidecar → finite bounded corrections).
- Full `swift test` green.

## Out of scope (v1)
- Manual subject selection (auto-detect largest person/face only).
- Subject scale-lock (translation-only for v1).
- Multiple subjects.

## Notes
- Global hand-shake stays on the **baked vid.stab** engine (default) — unchanged.
- Same OOM/main-thread discipline: tracking runs in the background queue; never a subprocess/Vision
  on the main thread inside a SwiftUI body.
