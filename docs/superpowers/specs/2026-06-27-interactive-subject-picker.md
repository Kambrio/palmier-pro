# Interactive Subject Picker for Subject Lock

**Date:** 2026-06-27
**Branch:** `subject-tracking` (off `main`)
**Supersedes:** the auto-detect-largest v1 in `2026-06-27-subject-tracking-stabilization.md`

## Goal
Let the user choose *which* object Subject Lock stabilizes by **clicking a detected-object rectangle
on the preview**, instead of auto-detecting the largest person/face. Detection uses a bundled
YOLO11n Core ML model; tracking + smoothing reuse the existing `VNTrackObjectRequest` +
`PathSmoother` + compositor path unchanged.

## Why this stack (research-backed, not invented)
- Apple Vision has **no general object detector** (only humans/faces/animals/saliency/text), so a
  **YOLO → Core ML** model run via `VNCoreMLRequest` is the standard way to get clickable labeled
  boxes for *any* object. Verified on this Mac: YOLO11n (NMS baked in) returns
  `VNRecognizedObjectObservation` (label + normalized box) correctly — the reported macOS-15.2 box
  bug does not affect us.
- Tracking the chosen object: **`VNTrackObjectRequest`** seeded with the picked box (Apple's
  official multi-object-tracking pattern) — already used by the v1 tracker.

## Model delivery
YOLO11n is **5.2 MB → bundled**, not downloaded. `Sources/PalmierPro/Resources/Models/Detector.mlmodelc`
(precompiled), added to `Package.swift` `.copy("Resources/Models")` and flattened by `bundle.sh`.
Conversion source-of-truth: `models/yolo11/export.py` + `README.md`. Loaded via `Bundle.module`.

## Coordinate conventions (critical — most likely bug source)
- **Vision** boxes: normalized, **bottom-left** origin.
- **UI overlay** (`PreviewHitTester.clipFrame` / `TransformOverlayView`): normalized **top-left**.
- **Store the seed box in TOP-LEFT normalized** (matches UI + `Stabilization`). Convert to Vision
  bottom-left only when seeding the tracker: `visionBox = CGRect(x, 1-(y+h), w, h)`.
- `SubjectTracker` already emits center top-left (`cy = 1 - box.midY`). Keep that.

## Components

### 1. `ObjectDetector.swift` (new, `Sources/PalmierPro/Stabilization/`)
```swift
struct DetectedObject: Identifiable, Sendable {
    let id: Int            // index in the result set
    let label: String      // e.g. "person"
    let confidence: Float
    let box: CGRect        // normalized, TOP-LEFT origin (already converted from Vision)
}
@MainActor final class ObjectDetector {
    static let shared: ObjectDetector
    func detect(in image: CGImage) async throws -> [DetectedObject]
}
```
- Lazy-load `VNCoreMLModel` once from `Bundle.module.url(forResource: "Models/Detector", withExtension: "mlmodelc")`
  (fall back to `Detector.mlmodelc` flattened path in the app bundle). Cache it.
- `VNCoreMLRequest`, `imageCropAndScaleOption = .scaleFill`. Run the handler **off the main thread**.
- Map each `VNRecognizedObjectObservation`: `label = labels.first.identifier`, convert box to top-left.
- Keep confidence ≥ 0.25, sort by confidence, cap to ~20. Never run inference in a SwiftUI body.

### 2. Model — `Stabilization` seed (`Models/Stabilization.swift`)
```swift
struct SubjectSeed: Codable, Equatable, Sendable {
    var frame: Int         // source-frame index the box was picked on
    var box: CGRect        // normalized, TOP-LEFT
    var label: String
}
var subjectSeed: SubjectSeed? = nil   // on Stabilization
```
`decodeIfPresent(... ) ?? nil` in the custom decoder. A seed identity string
`"<frame>|<box rounded>|<label>"` keys the sidecar (below).

### 3. `SubjectTracker` — seeded variant
```swift
static func track(input: URL, seedFrame: Int, seedBoxTopLeft: CGRect,
                  progress: @escaping @Sendable (Double) -> Void)
    async throws -> (fps: Double, frames: [StabFrameTransform])
```
- Convert `seedBoxTopLeft` → Vision bottom-left for `VNDetectedObjectObservation`.
- Track **forward** from `seedFrame` to end (seed `VNTrackObjectRequest` at `seedFrame`).
- Track **backward** for `[0, seedFrame)`: buffer those frames as `CVPixelBuffer`s (autoreleasepool,
  bounded by `maxBackwardFrames = 900`; beyond the cap, hold the seed center constant and `log`), feed
  them reversed through a second `VNSequenceRequestHandler`. This works because tracking runs on the
  **proxy** when available (low-res → small buffers).
- Per frame center → `StabFrameTransform(m:[1,0,cx, 0,1,cy, 0,0,1])`, top-left. Carry last center on a
  dropped/lost frame. `frames.count == source frame count`. Same OOM discipline as v1.
- Keep the existing auto-detect `track(input:progress:)` as a fallback for clips with no seed.

### 4. Sidecar — keyed by seed (`StabilizationSidecar.swift`)
- `SubjectSidecar` gains `seedKey: String`. File becomes `<assetId>.<seedHash>.subject.json` so
  different picks of the same asset coexist. `read(assetId:baseDir:sourceSig:seedKey:)` requires
  version + sourceSig + seedKey match. Bump `SubjectSidecarStore.currentVersion`.

### 5. `StabilizationManager`
- `enqueueSubjectTrack(assetId:url:seed:)`, `runSubjectTrack` → seeded `SubjectTracker.track`, writes
  sidecar keyed by `seed`. `hasSubjectTrack(assetId:seed:)`.
- `corrections(for:)` `.subject` branch: read sidecar by the clip's `stabilization.subjectSeed`
  (return nil if no seed yet → no correction until the user picks). Same windowing + position-only L1.
- `reconcileSubjectClips`: enqueue only `.subject` clips that **have a seed** and lack a matching
  sidecar. Clips with `.subject` but no seed are left for the user to pick.

### 6. Inspector + preview overlay
- `InspectorView.stabilizationSection`: when `engine == .subject`, show a **"Choose subject…"**
  button + the current pick label ("Tracking: person", or "No subject selected"). The button enters
  selection mode. Selecting `.subject` no longer auto-tracks; it prompts the pick.
- Selection session on `EditorViewModel`:
  ```swift
  struct SubjectPickerSession { var clipId: String; var frame: Int; var objects: [DetectedObject] }
  var subjectPicker: SubjectPickerSession? = nil
  ```
  Entering: grab the current playhead frame `CGImage` (VideoEngine `AVAssetImageGenerator` at the
  clip's source frame, full-ish res), run `ObjectDetector.detect`, store session.
- New `SubjectPickerOverlay` in the preview ZStack (mirror `TransformOverlayView`): when a session is
  active, draw each `DetectedObject` as a labeled, tappable rectangle mapped via
  `PreviewHitTester.videoContentRect` + `clipFrame`. Click → write
  `SubjectSeed{frame, box, label}` onto the clip's `stabilization.subjectSeed`, clear the session,
  `enqueueSubjectTrack(seed:)`. An Esc / click-outside cancels.

## Tests
- `ObjectDetectorTests`: model loads from bundle; `detect` on a generated image returns boxes all
  within 0..1 and finite; labels non-empty. (Don't assert specific classes on synthetic input.)
- `SubjectTrackerSeededTests`: synthesize a moving bright rectangle on textured bg; seed at frame K
  with its box; assert recovered center path follows the rectangle **before and after** K (tolerance).
- `StabilizationDecodeTests`: `subjectSeed` decodeIfPresent fallback nil; round-trips when present.
- Coordinate round-trip: top-left ↔ Vision bottom-left ↔ top-left is identity.
- `corrections(for:)` subject branch with a seed → finite bounded corrections; nil when no seed.
- Full `swift test` green.

## Out of scope (v1)
- Multiple simultaneous subjects; box editing after pick (re-pick instead); scale-lock
  (translation-only); animal/landmark-specific detectors. Global hand-shake stays on baked vid.stab.
