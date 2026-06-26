# Video Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native non-destructive video stabilization — analyze camera motion with Vision, smooth it, apply per-frame correction through the existing Core Image compositor without writing new media.

**Architecture:** Offline `StabilizationAnalyzer` (Vision) produces a per-source-frame raw camera path, cached as a sidecar per asset (keyed by source signature, like proxies). A pure `PathSmoother` turns raw path + clip params into per-frame correction transforms + an auto-crop zoom. `FrameRenderer` prepends the correction to the existing per-frame affine (similarity modes) or applies `CIPerspectiveTransform` (perspective mode). `StabilizationManager` runs analysis in the background, mirroring `ProxyManager`.

**Tech Stack:** Swift 6.2, Vision (`VNHomographicImageRegistrationRequest`, `VNTranslationalImageRegistrationRequest`), AVFoundation (`AVAssetReader`), Core Image / Metal, Swift Testing.

**Build/test commands:** `swift build` · `swift test --filter <Suite>`

---

## File Structure

**New:**
- `Sources/PalmierPro/Models/Stabilization.swift` — `StabMethod`, `Stabilization` value types
- `Sources/PalmierPro/Stabilization/StabFrameTransform.swift` — `StabFrameTransform` (serializable per-frame motion) + helpers
- `Sources/PalmierPro/Stabilization/StabilizationSidecar.swift` — sidecar codec + on-disk paths + staleness
- `Sources/PalmierPro/Stabilization/PathSmoother.swift` — pure smoothing + crop-factor
- `Sources/PalmierPro/Stabilization/StabilizationAnalyzer.swift` — Vision frame-walk → raw path
- `Sources/PalmierPro/Stabilization/StabilizationManager.swift` — `@MainActor @Observable` background job
- `Sources/PalmierPro/Editor/Inspector/StabilizationInspectorSection.swift` — UI
- `Tests/PalmierProTests/PathSmootherTests.swift`
- `Tests/PalmierProTests/StabilizationSidecarTests.swift`
- `Tests/PalmierProTests/StabilizationAnalyzerTests.swift`

**Modified:**
- `Sources/PalmierPro/Models/Timeline.swift` — `Clip.stabilization` + `CodingKeys`
- `Sources/PalmierPro/Utilities/Constants.swift` — `stabilizationDirname`
- `Sources/PalmierPro/Compositing/FrameRenderer.swift` — correction hook in `composedLayer`
- Clip inspector container — mount `StabilizationInspectorSection`

> **Note on test paths:** confirm the exact test directory by checking an existing test file's location (`rg -l "import Testing" Tests`). Use that directory for the new test files; paths below assume `Tests/PalmierProTests/`.

---

## Task 1: Stabilization value model

**Files:**
- Create: `Sources/PalmierPro/Models/Stabilization.swift`
- Modify: `Sources/PalmierPro/Models/Timeline.swift:101-118`

- [ ] **Step 1: Create the model**

`Sources/PalmierPro/Models/Stabilization.swift`:
```swift
import Foundation

/// How aggressively the correction is allowed to transform each frame.
enum StabMethod: String, Codable, Sendable, CaseIterable {
    case position       // translation only
    case similarity     // translation + scale + rotation (default)
    case perspective    // full homography

    var displayName: String {
        switch self {
        case .position:    "Position"
        case .similarity:  "Position, Scale & Rotation"
        case .perspective: "Perspective"
        }
    }
}

/// Per-clip stabilization parameters. Cheap to store; the expensive raw camera
/// path lives in a per-asset sidecar (see StabilizationSidecar).
struct Stabilization: Codable, Sendable, Equatable {
    var enabled: Bool = true
    var method: StabMethod = .similarity
    /// 0…1 — drives the smoothing window. Higher = smoother / more locked-down.
    var smoothness: Double = 0.5
    /// Auto-zoom so counter-motion never exposes the frame edges.
    var cropToFit: Bool = true
}
```

- [ ] **Step 2: Add the field to `Clip`**

In `Sources/PalmierPro/Models/Timeline.swift`, after `var effects: [Effect]?` (line 109):
```swift
    var effects: [Effect]?

    /// Non-destructive stabilization parameters; nil when disabled/never applied.
    var stabilization: Stabilization?
```
And add `stabilization` to `CodingKeys` (after `case effects`, line 118):
```swift
        case effects
        case stabilization
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Models/Stabilization.swift Sources/PalmierPro/Models/Timeline.swift
git commit -m "feat(stabilization): add Stabilization model and Clip.stabilization field"
```

---

## Task 2: Per-frame transform type + sidecar codec

A `StabFrameTransform` is the serializable per-frame motion. We store a full 3×3
homography as a flat 9-float array (works for all three modes; similarity/position
just constrain it at apply time). Sidecar is one JSON file per asset.

**Files:**
- Create: `Sources/PalmierPro/Stabilization/StabFrameTransform.swift`
- Create: `Sources/PalmierPro/Stabilization/StabilizationSidecar.swift`
- Modify: `Sources/PalmierPro/Utilities/Constants.swift:116`
- Test: `Tests/PalmierProTests/StabilizationSidecarTests.swift`

- [ ] **Step 1: Create `StabFrameTransform`**

`Sources/PalmierPro/Stabilization/StabFrameTransform.swift`:
```swift
import Foundation
import simd

/// One frame's motion as a normalized-coordinate homography (row-major 3×3),
/// stored flat for Codable. Identity = no motion.
struct StabFrameTransform: Codable, Sendable, Equatable {
    var m: [Double]   // 9 elements, row-major

    static let identity = StabFrameTransform(m: [1,0,0, 0,1,0, 0,0,1])

    init(m: [Double]) { self.m = m.count == 9 ? m : Self.identity.m }

    init(_ matrix: simd_double3x3) {
        // simd is column-major; flatten to row-major.
        m = [
            matrix[0][0], matrix[1][0], matrix[2][0],
            matrix[0][1], matrix[1][1], matrix[2][1],
            matrix[0][2], matrix[1][2], matrix[2][2],
        ]
    }

    var matrix: simd_double3x3 {
        simd_double3x3(rows: [
            SIMD3(m[0], m[1], m[2]),
            SIMD3(m[3], m[4], m[5]),
            SIMD3(m[6], m[7], m[8]),
        ])
    }
}
```

- [ ] **Step 2: Add the sidecar dir name constant**

In `Sources/PalmierPro/Utilities/Constants.swift`, after `proxiesDirname` (line 116):
```swift
    static let proxiesDirname = "proxies"
    /// Subdirectory of `media/` holding per-asset stabilization analysis sidecars.
    static let stabilizationDirname = "stabilization"
```

- [ ] **Step 3: Write the failing sidecar test**

`Tests/PalmierProTests/StabilizationSidecarTests.swift`:
```swift
import Testing
import Foundation
@testable import PalmierPro

struct StabilizationSidecarTests {
    @Test func roundTripsTransforms() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = StabSidecar(
            sourceSig: "abc123",
            fps: 30,
            frames: [.identity, StabFrameTransform(m: [1,0,0.1, 0,1,0.2, 0,0,1])]
        )
        try StabilizationSidecar.write(payload, assetId: "asset1", baseDir: dir)
        let loaded = try #require(StabilizationSidecar.read(assetId: "asset1", baseDir: dir))
        #expect(loaded.frames.count == 2)
        #expect(loaded.frames[1].m[2] == 0.1)
        #expect(loaded.sourceSig == "abc123")
    }

    @Test func staleSidecarIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try StabilizationSidecar.write(
            StabSidecar(sourceSig: "old", fps: 30, frames: [.identity]),
            assetId: "asset1", baseDir: dir)
        #expect(StabilizationSidecar.read(assetId: "asset1", baseDir: dir, requiringSig: "new") == nil)
        #expect(StabilizationSidecar.read(assetId: "asset1", baseDir: dir, requiringSig: "old") != nil)
    }
}
```

- [ ] **Step 4: Run test, expect failure**

Run: `swift test --filter StabilizationSidecarTests`
Expected: FAIL — `StabSidecar` / `StabilizationSidecar` undefined.

- [ ] **Step 5: Implement the sidecar**

`Sources/PalmierPro/Stabilization/StabilizationSidecar.swift`:
```swift
import Foundation

/// On-disk per-asset analysis payload.
struct StabSidecar: Codable, Sendable, Equatable {
    var sourceSig: String      // ProxySignature.of(sourceURL) when analyzed
    var fps: Double            // source fps the frames were sampled at
    var frames: [StabFrameTransform]   // index = source frame
}

enum StabilizationSidecar {
    static func dir(baseDir: URL) -> URL {
        baseDir.appendingPathComponent(
            "\(Project.mediaDirectoryName)/\(Project.stabilizationDirname)", isDirectory: true)
    }

    /// `baseDir` is the project package URL when used in-app; tests pass a temp dir directly.
    private static func fileURL(assetId: String, baseDir: URL) -> URL {
        dir(baseDir: baseDir).appendingPathComponent("\(assetId).json")
    }

    static func write(_ payload: StabSidecar, assetId: String, baseDir: URL) throws {
        let url = fileURL(assetId: assetId, baseDir: baseDir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: url, options: .atomic)
    }

    static func read(assetId: String, baseDir: URL, requiringSig: String? = nil) -> StabSidecar? {
        let url = fileURL(assetId: assetId, baseDir: baseDir)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(StabSidecar.self, from: data) else { return nil }
        if let sig = requiringSig, payload.sourceSig != sig { return nil }
        return payload
    }
}
```

> Note: `StabilizationSidecar.write` writes under `<baseDir>/media/stabilization/`; tests pass a temp `baseDir` so the structure is identical to production.

- [ ] **Step 6: Run test, expect pass**

Run: `swift test --filter StabilizationSidecarTests`
Expected: PASS (both tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/PalmierPro/Stabilization/StabFrameTransform.swift Sources/PalmierPro/Stabilization/StabilizationSidecar.swift Sources/PalmierPro/Utilities/Constants.swift Tests/PalmierProTests/StabilizationSidecarTests.swift
git commit -m "feat(stabilization): per-frame transform type and per-asset sidecar codec"
```

---

## Task 3: PathSmoother (pure)

The heart. Input: raw per-frame transforms (cumulative camera path is built
internally), the visible source-frame window `[first, last]`, `method`, `smoothness`,
`cropToFit`. Output: per-frame correction transforms for that window + a single crop
zoom factor.

For v1, model motion as **translation + rotation + uniform scale** extracted from each
homography (this covers position & similarity exactly; perspective passes the residual
homography through unchanged — handled in Task 7). Smoothing is a Gaussian low-pass on
the cumulative translation/rotation/scale signals; correction = smoothed − raw.

**Files:**
- Create: `Sources/PalmierPro/Stabilization/PathSmoother.swift`
- Test: `Tests/PalmierProTests/PathSmootherTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/PalmierProTests/PathSmootherTests.swift`:
```swift
import Testing
import Foundation
@testable import PalmierPro

struct PathSmootherTests {
    // A purely smooth pan should be left ~untouched (correction ≈ identity translation).
    @Test func smoothMotionNeedsLittleCorrection() {
        let frames = (0..<60).map { i -> StabFrameTransform in
            StabFrameTransform(m: [1,0, Double(i) * 0.001, 0,1,0, 0,0,1])  // steady drift
        }
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<60, method: .similarity, smoothness: 0.5, cropToFit: false)
        let maxTx = out.corrections.map { abs($0.m[2]) }.max() ?? 1
        #expect(maxTx < 0.01)
    }

    // High-frequency jitter must be reduced: correction translation should oppose it.
    @Test func jitterIsReduced() {
        let frames = (0..<60).map { i -> StabFrameTransform in
            let jitter = (i % 2 == 0 ? 0.05 : -0.05)
            return StabFrameTransform(m: [1,0, jitter, 0,1,0, 0,0,1])
        }
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<60, method: .position, smoothness: 0.8, cropToFit: false)
        // Residual jitter after applying corrections is smaller than the input jitter.
        let residual = zip(frames, out.corrections).map { abs($0.m[2] + $1.m[2]) }.max() ?? 1
        #expect(residual < 0.05)
    }

    @Test func cropFactorAtLeastOne() {
        let frames = (0..<30).map { i in
            StabFrameTransform(m: [1,0, Double(i % 3) * 0.04, 0,1,0, 0,0,1])
        }
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<30, method: .similarity, smoothness: 0.5, cropToFit: true)
        #expect(out.cropZoom >= 1.0)
    }

    @Test func emptyWindowIsSafe() {
        let out = PathSmoother.corrections(
            raw: [], window: 0..<0, method: .similarity, smoothness: 0.5, cropToFit: true)
        #expect(out.corrections.isEmpty)
        #expect(out.cropZoom == 1.0)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `swift test --filter PathSmootherTests`
Expected: FAIL — `PathSmoother` undefined.

- [ ] **Step 3: Implement `PathSmoother`**

`Sources/PalmierPro/Stabilization/PathSmoother.swift`:
```swift
import Foundation
import simd

enum PathSmoother {
    struct Result: Sendable, Equatable {
        var corrections: [StabFrameTransform]   // one per frame in `window`
        var cropZoom: Double                    // ≥ 1.0
    }

    /// Decomposed 2D camera state we smooth independently.
    private struct State { var tx: Double; var ty: Double; var rot: Double; var scale: Double }

    private static func decompose(_ t: StabFrameTransform) -> State {
        // Interpret the upper-left 2×2 + translation column of the homography.
        let a = t.m[0], b = t.m[1], c = t.m[3], d = t.m[4]
        let scale = (hypot(a, c) + hypot(b, d)) / 2
        let rot = atan2(c, a)
        return State(tx: t.m[2], ty: t.m[5], rot: rot, scale: scale == 0 ? 1 : scale)
    }

    /// Build a homography that applies (tx,ty,rot,scale) about the frame center (0.5,0.5).
    private static func compose(_ s: State) -> StabFrameTransform {
        let cs = cos(s.rot) * s.scale, sn = sin(s.rot) * s.scale
        // Rotate/scale about (0.5,0.5), then translate.
        let cx = 0.5, cy = 0.5
        let tx = s.tx + cx - (cs * cx - sn * cy)
        let ty = s.ty + cy - (sn * cx + cs * cy)
        return StabFrameTransform(m: [cs, -sn, tx, sn, cs, ty, 0, 0, 1])
    }

    static func corrections(
        raw: [StabFrameTransform],
        window: Range<Int>,
        method: StabMethod,
        smoothness: Double,
        cropToFit: Bool
    ) -> Result {
        let idx = Array(window).filter { $0 >= 0 && $0 < raw.count }
        guard !idx.isEmpty else { return Result(corrections: [], cropZoom: 1.0) }

        // 1. Build cumulative camera path over the window.
        var cum: [State] = []
        var acc = State(tx: 0, ty: 0, rot: 0, scale: 1)
        for i in idx {
            let d = decompose(raw[i])
            acc = State(tx: acc.tx + d.tx, ty: acc.ty + d.ty,
                        rot: acc.rot + d.rot, scale: acc.scale * d.scale)
            cum.append(acc)
        }

        // 2. Gaussian-smooth each channel. smoothness 0…1 → sigma 1…30 frames.
        let sigma = 1 + smoothness * 29
        let txS = gaussian(cum.map(\.tx), sigma: sigma)
        let tyS = gaussian(cum.map(\.ty), sigma: sigma)
        let rotS = method == .position ? cum.map { _ in 0.0 } : gaussian(cum.map(\.rot), sigma: sigma)
        let scS  = method == .position ? cum.map { _ in cum.first!.scale }
                                       : gaussian(cum.map(\.scale), sigma: sigma)

        // 3. Correction = smoothed − raw cumulative, expressed as a homography.
        var corrections: [StabFrameTransform] = []
        var maxAbsTx = 0.0, maxAbsTy = 0.0
        for k in cum.indices {
            let cor = State(tx: txS[k] - cum[k].tx,
                            ty: tyS[k] - cum[k].ty,
                            rot: (method == .position) ? 0 : rotS[k] - cum[k].rot,
                            scale: (method == .position) ? 1 : scS[k] / cum[k].scale)
            corrections.append(compose(cor))
            maxAbsTx = max(maxAbsTx, abs(cor.tx)); maxAbsTy = max(maxAbsTy, abs(cor.ty))
        }

        // 4. Crop zoom: enough scale-up that the largest translation never exposes an edge.
        let cropZoom = cropToFit ? 1 + 2 * max(maxAbsTx, maxAbsTy) : 1.0
        return Result(corrections: corrections, cropZoom: max(1.0, cropZoom))
    }

    private static func gaussian(_ xs: [Double], sigma: Double) -> [Double] {
        guard xs.count > 1, sigma > 0 else { return xs }
        let radius = max(1, Int((sigma * 3).rounded()))
        var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = kernel.reduce(0, +); kernel = kernel.map { $0 / sum }
        return xs.indices.map { i in
            var acc = 0.0
            for (k, w) in kernel.enumerated() {
                let j = min(max(i + k - radius, 0), xs.count - 1)
                acc += xs[j] * w
            }
            return acc
        }
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `swift test --filter PathSmootherTests`
Expected: PASS (4 tests). If `jitterIsReduced` is marginal, raise its `smoothness` toward 1.0 — do not loosen the assertion below input jitter.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Stabilization/PathSmoother.swift Tests/PalmierProTests/PathSmootherTests.swift
git commit -m "feat(stabilization): pure path smoother with crop-zoom computation"
```

---

## Task 4: StabilizationAnalyzer (Vision)

Walks an asset's frames at reduced resolution via `AVAssetReader`, runs Vision
registration on consecutive pairs, returns `[StabFrameTransform]` (index = source
frame, frame 0 = identity). Follows the reader setup in
`ProxyService.transcode` (`Proxy/ProxyService.swift:17-36`).

**Files:**
- Create: `Sources/PalmierPro/Stabilization/StabilizationAnalyzer.swift`
- Test: `Tests/PalmierProTests/StabilizationAnalyzerTests.swift`

- [ ] **Step 1: Implement the analyzer**

`Sources/PalmierPro/Stabilization/StabilizationAnalyzer.swift`:
```swift
import AVFoundation
import Vision
import CoreImage
import simd

enum StabilizationAnalyzer {
    struct Failure: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    /// Long-edge resolution frames are scaled to before registration (speed vs. accuracy).
    static let analysisLongEdge: CGFloat = 540

    /// Returns one transform per source frame; element 0 is identity. `progress` is 0…1.
    /// Throws CancellationError if the surrounding Task is cancelled.
    static func analyze(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (fps: Double, frames: [StabFrameTransform]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(reason: "no video track")
        }
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let estTotal = max(1, Int((duration * max(1, fps)).rounded()))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure(reason: "reader failed to start") }

        var frames: [StabFrameTransform] = [.identity]
        var previous: CVPixelBuffer?
        var count = 0

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            defer { previous = buffer }
            count += 1
            guard let prev = previous else { continue }   // first frame: identity already pushed
            frames.append(register(from: prev, to: buffer))
            if count % 10 == 0 { progress(min(1, Double(count) / Double(estTotal))) }
        }
        if reader.status == .failed { throw Failure(reason: reader.error?.localizedDescription ?? "read error") }
        progress(1)
        return (fps == 0 ? 30 : fps, frames)
    }

    /// Homographic registration with translational fallback; result is a normalized homography.
    private static func register(from prev: CVPixelBuffer, to curr: CVPixelBuffer) -> StabFrameTransform {
        let handler = VNSequenceRequestHandler()
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: curr)
        do {
            try handler.perform([request], on: prev)
            if let obs = request.results?.first as? VNImageHomographicAlignmentObservation {
                let m = obs.warpTransform   // matrix_float3x3, normalized
                let h = simd_double3x3(
                    SIMD3(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
                    SIMD3(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
                    SIMD3(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)))
                let t = StabFrameTransform(h)
                if t.m.allSatisfy({ $0.isFinite }) { return t }
            }
        } catch { /* fall through to translational */ }

        let treq = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: curr)
        if (try? handler.perform([treq], on: prev)) != nil,
           let obs = treq.results?.first as? VNImageTranslationAlignmentObservation {
            let a = obs.alignmentTransform   // CGAffineTransform in pixel units
            let w = CGFloat(CVPixelBufferGetWidth(curr)), hgt = CGFloat(CVPixelBufferGetHeight(curr))
            return StabFrameTransform(m: [1, 0, Double(a.tx / max(1, w)),
                                          0, 1, Double(a.ty / max(1, hgt)),
                                          0, 0, 1])
        }
        return .identity
    }
}
```

> If `VNHomographicImageRegistrationRequest(targetedCVPixelBuffer:)` or `warpTransform` differ in the installed SDK, check Vision's current registration API and adapt; the structure (homographic → translational fallback → normalized `StabFrameTransform`) stays the same.

- [ ] **Step 2: Write an integration test (small fixture)**

`Tests/PalmierProTests/StabilizationAnalyzerTests.swift`:
```swift
import Testing
import AVFoundation
@testable import PalmierPro

struct StabilizationAnalyzerTests {
    // Synthesize a short clip that pans right by a fixed amount each frame, then
    // assert the analyzer recovers a consistent non-zero horizontal motion.
    @Test func recoversHorizontalPan() async throws {
        let url = try await TestClip.makePanningClip(frames: 20, pxPerFrame: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, frames) = try await StabilizationAnalyzer.analyze(url: url, progress: { _ in })
        #expect(frames.count >= 18)
        // Most inter-frame transforms should report horizontal translation of one sign.
        let txs = frames.dropFirst().map { $0.m[2] }
        let movingFrames = txs.filter { abs($0) > 0.001 }
        #expect(movingFrames.count >= txs.count / 2)
    }
}
```

- [ ] **Step 3: Add the test-clip generator helper**

Add `TestClip.makePanningClip` to the test target. Create `Tests/PalmierProTests/TestClip.swift`:
```swift
import AVFoundation
import CoreImage
import Foundation

/// Generates synthetic clips for stabilization tests.
enum TestClip {
    /// A clip where a bright square slides horizontally `pxPerFrame` each frame.
    static func makePanningClip(frames: Int, pxPerFrame: Int, size: Int = 256) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let ctx = CIContext()
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32ARGB, nil, &pb)
            guard let buffer = pb else { continue }
            let x = CGFloat(20 + i * pxPerFrame)
            let img = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
            let sq = CIImage(color: .white)
                .cropped(to: CGRect(x: x, y: CGFloat(size/2 - 20), width: 40, height: 40))
                .composited(over: img)
            ctx.render(sq, to: buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
}
```

- [ ] **Step 4: Run the analyzer test**

Run: `swift test --filter StabilizationAnalyzerTests`
Expected: PASS. If Vision returns mostly identity on this synthetic clip (low texture), add a textured background to `makePanningClip` (e.g. a noise/gradient image instead of solid black) so registration has features to track, then re-run.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Stabilization/StabilizationAnalyzer.swift Tests/PalmierProTests/StabilizationAnalyzerTests.swift Tests/PalmierProTests/TestClip.swift
git commit -m "feat(stabilization): Vision-based camera-motion analyzer"
```

---

## Task 5: StabilizationManager (background job)

Mirrors `ProxyManager` (`Proxy/ProxyManager.swift`): background `Task`, semaphore gate,
progress fields, sidecar read/write, staleness via `ProxySignature.of`. Exposes a
sync `corrections(for:)` the renderer can call cheaply.

**Files:**
- Create: `Sources/PalmierPro/Stabilization/StabilizationManager.swift`

- [ ] **Step 1: Implement the manager**

`Sources/PalmierPro/Stabilization/StabilizationManager.swift`:
```swift
import Foundation
import os

@MainActor
@Observable
final class StabilizationManager {
    private unowned let editor: EditorViewModel
    private static let gate = AsyncSemaphore(value: 1)
    private(set) var isAnalyzing = false
    private(set) var completed = 0
    private(set) var total = 0
    /// assetId → analyzing progress (0…1) for HUD/inspector.
    private(set) var progressByAsset: [String: Double] = [:]
    private var job: Task<Void, Never>?
    /// In-memory cache of correction results keyed by assetId+params hash.
    private var correctionCache: [String: PathSmoother.Result] = [:]

    init(editor: EditorViewModel) { self.editor = editor }

    private var baseDir: URL? { editor.projectURL }

    func hasAnalysis(assetId: String) -> Bool {
        guard let base = baseDir,
              let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else { return false }
        return StabilizationSidecar.read(
            assetId: assetId, baseDir: base, requiringSig: ProxySignature.of(asset.url)) != nil
    }

    /// Analyze the asset behind `clip` if not already cached; no-op if running/unsaved.
    func analyze(assetId: String, url: URL) {
        guard !isAnalyzing, baseDir != nil else { return }
        isAnalyzing = true; completed = 0; total = 1
        job = Task { [weak self] in
            await self?.run(assetId: assetId, url: url)
            self?.isAnalyzing = false
        }
    }

    func cancel() { job?.cancel(); job = nil; isAnalyzing = false }

    private func run(assetId: String, url: URL) async {
        guard let base = baseDir, (try? await Self.gate.wait()) != nil else { return }
        defer { Task { await Self.gate.signal() } }
        progressByAsset[assetId] = 0
        do {
            let (fps, frames) = try await StabilizationAnalyzer.analyze(url: url) { p in
                Task { @MainActor [weak self] in self?.progressByAsset[assetId] = p }
            }
            let payload = StabSidecar(sourceSig: ProxySignature.of(url), fps: fps, frames: frames)
            try StabilizationSidecar.write(payload, assetId: assetId, baseDir: base)
            correctionCache.removeAll()   // params unchanged but raw path is new
            completed = 1
            progressByAsset[assetId] = 1
            editor.onPersistentStateChanged?()
            editor.videoEngine?.rebuild()
        } catch is CancellationError {
            progressByAsset[assetId] = nil
        } catch {
            Log.proxy.error("stabilization analyze failed id=\(assetId.prefix(8)): \(Log.detail(error))")
            progressByAsset[assetId] = nil
        }
    }

    /// Per-frame corrections for a clip, computed from the cached sidecar + clip params.
    /// Returns nil when no analysis exists or stabilization is disabled.
    func corrections(for clip: Clip, assetURL: URL) -> PathSmoother.Result? {
        guard let stab = clip.stabilization, stab.enabled, let base = baseDir else { return nil }
        let key = "\(clip.mediaRef)|\(stab.method.rawValue)|\(stab.smoothness)|\(stab.cropToFit)|\(clip.trimStartFrame)|\(clip.durationFrames)"
        if let hit = correctionCache[key] { return hit }
        guard let sidecar = StabilizationSidecar.read(
            assetId: clip.mediaRef, baseDir: base,
            requiringSig: ProxySignature.of(assetURL)) else { return nil }
        let start = clip.trimStartFrame
        let end = min(sidecar.frames.count, start + clip.sourceFramesConsumed)
        let result = PathSmoother.corrections(
            raw: sidecar.frames, window: start..<max(start, end),
            method: stab.method, smoothness: stab.smoothness, cropToFit: stab.cropToFit)
        correctionCache[key] = result
        return result
    }

    func invalidateCache() { correctionCache.removeAll() }
}
```

> Verify `ProxySignature.of`, `AsyncSemaphore`, `Log.proxy`, `editor.mediaAssets`, `editor.projectURL`, `editor.videoEngine?.rebuild()`, and `editor.onPersistentStateChanged?()` against `ProxyManager.swift` — they are used identically there.

- [ ] **Step 2: Wire the manager onto the editor**

Find where `ProxyManager` is instantiated on `EditorViewModel` (`rg -n "ProxyManager(editor" Sources`). Add a sibling:
```swift
    lazy var stabilizationManager = StabilizationManager(editor: self)
```
matching the existing `proxyManager` declaration's style/placement.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Stabilization/StabilizationManager.swift Sources/PalmierPro/Editor/ViewModel/
git commit -m "feat(stabilization): background analysis manager with correction cache"
```

---

## Task 6: Render hook — similarity & position modes

Apply the per-frame correction (affine) inside `FrameRenderer.composedLayer`, folded
into the existing transform chain. The correction is in normalized [0,1] frame
coordinates; convert to the layer's `natSize` pixel space, apply the crop-zoom about
the image center.

**Files:**
- Modify: `Sources/PalmierPro/Compositing/FrameRenderer.swift:85-92`
- Modify: `LayerPlan` (wherever it's defined — `rg -n "struct LayerPlan"`) to carry the correction + asset URL, OR pass corrections via the instruction. Prefer adding a resolved `stabCorrection: CGAffineTransform?` and `stabZoom: CGFloat` to `LayerPlan`, computed when the instruction is built.

- [ ] **Step 1: Add correction fields to `LayerPlan`**

In the `LayerPlan` definition, add:
```swift
    /// Per-frame stabilization correction in natSize pixel space (nil = none). Indexed by clip-relative frame.
    var stabCorrections: [CGAffineTransform]?
    var stabZoom: CGFloat = 1
```

- [ ] **Step 2: Populate it where instructions/layers are built**

Where `LayerPlan`s are constructed (in `CompositionBuilder` / `CompositorInstruction` build path — `rg -n "LayerPlan("`), resolve corrections once per clip:
```swift
let stab = editor.stabilizationManager.corrections(for: clip, assetURL: resolvedSourceURL)
let zoom = CGFloat(stab?.cropZoom ?? 1)
let affines: [CGAffineTransform]? = stab.map { r in
    r.corrections.map { Self.normalizedHomographyToAffine($0, natSize: natSize, zoom: zoom) }
}
```
Add the conversion helper in `CompositionBuilder`:
```swift
/// Convert a normalized-coordinate correction (about frame center) to a natSize-pixel affine,
/// pre-scaled by the crop zoom about the image center.
static func normalizedHomographyToAffine(_ t: StabFrameTransform, natSize: CGSize, zoom: CGFloat) -> CGAffineTransform {
    let m = t.m
    // Normalized affine (drop the projective row for similarity/position).
    let normalized = CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5])
    let toPx = CGAffineTransform(scaleX: natSize.width, y: natSize.height)
    let fromPx = CGAffineTransform(scaleX: 1 / natSize.width, y: 1 / natSize.height)
    // px-space correction = toPx * normalized * fromPx
    var px = fromPx.concatenating(normalized).concatenating(toPx)
    // Apply crop zoom about the image center.
    let cx = natSize.width / 2, cy = natSize.height / 2
    let zoomT = CGAffineTransform(translationX: cx, y: cy)
        .scaledBy(x: zoom, y: zoom)
        .translatedBy(x: -cx, y: -cy)
    px = px.concatenating(zoomT)
    return px
}
```

> `LayerPlan` is `Sendable`/used off-main in the compositor; resolving `corrections` at build time (on main) and storing plain `CGAffineTransform`s keeps the renderer free of manager access.

- [ ] **Step 3: Apply it in `composedLayer`**

In `FrameRenderer.composedLayer`, replace lines 85-89:
```swift
        let t = clip.hasTransformAnimation ? clip.transformAt(frame: frame) : clip.transform
        let placement = CompositionBuilder.affineTransform(for: t, natSize: layer.natSize, renderSize: renderSize)
        var srcSpace = layer.preferredTransform
        if let corrections = layer.stabCorrections {
            let rel = max(0, min(corrections.count - 1, frame - clip.startFrame))
            // Prepend the correction in source/natSize space, before placement.
            srcSpace = layer.stabCorrections![rel].concatenating(srcSpace)
        }
        let av = srcSpace.concatenating(placement)
```

- [ ] **Step 4: Build + smoke test**

Run: `swift build`
Expected: builds clean. (Render correctness is verified manually in Task 8 via the app; the affine math is exercised by `PathSmoother`/conversion unit coverage.)

- [ ] **Step 5: Add a conversion unit test**

Append to `PathSmootherTests.swift` (or a new `StabRenderMathTests.swift`):
```swift
    @Test func identityCorrectionMapsToIdentityAffine() {
        let a = CompositionBuilder.normalizedHomographyToAffine(
            .identity, natSize: CGSize(width: 1920, height: 1080), zoom: 1)
        #expect(abs(a.a - 1) < 1e-9 && abs(a.d - 1) < 1e-9)
        #expect(abs(a.tx) < 1e-9 && abs(a.ty) < 1e-9)
    }

    @Test func zoomScalesAboutCenter() {
        let a = CompositionBuilder.normalizedHomographyToAffine(
            .identity, natSize: CGSize(width: 100, height: 100), zoom: 2)
        let center = CGPoint(x: 50, y: 50).applying(a)
        #expect(abs(center.x - 50) < 1e-6 && abs(center.y - 50) < 1e-6)  // center fixed
    }
```

- [ ] **Step 6: Run + commit**

Run: `swift test --filter PathSmootherTests` (or `StabRenderMathTests`)
Expected: PASS.
```bash
git add Sources/PalmierPro/Compositing/FrameRenderer.swift Sources/PalmierPro/Preview/CompositionBuilder.swift Tests/PalmierProTests/
git commit -m "feat(stabilization): apply similarity/position correction in compositor"
```

---

## Task 7: Perspective mode

For `method == .perspective`, apply the residual homography as a `CIPerspectiveTransform`
on the CIImage before placement, instead of folding into the affine.

**Files:**
- Modify: `Sources/PalmierPro/Compositing/FrameRenderer.swift`
- Modify: `LayerPlan` — add `var stabPerspective: [StabFrameTransform]?` (raw correction homographies, per clip-relative frame) populated only when method is `.perspective`.

- [ ] **Step 1: Populate perspective corrections at build time**

Where corrections are resolved (Task 6 Step 2), when `clip.stabilization?.method == .perspective`, store the raw correction homographies (from `PathSmoother.Result.corrections`) into `layer.stabPerspective` and leave `stabCorrections` nil.

- [ ] **Step 2: Apply `CIPerspectiveTransform` in `composedLayer`**

Before the placement transform (Task 6 Step 3), when `layer.stabPerspective` is set:
```swift
        if let homos = layer.stabPerspective {
            let rel = max(0, min(homos.count - 1, frame - clip.startFrame))
            image = applyPerspective(image, homos[rel], natSize: layer.natSize)
        }
```
Add the helper to `FrameRenderer`:
```swift
    /// Map a normalized correction homography to image-corner destinations and warp via Core Image.
    private static func applyPerspective(_ image: CIImage, _ t: StabFrameTransform, natSize: CGSize) -> CIImage {
        func warp(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            // normalized coords → apply homography → back to pixels
            let nx = x / natSize.width, ny = y / natSize.height
            let m = t.m
            let w = m[6]*nx + m[7]*ny + m[8]
            let ox = (m[0]*nx + m[1]*ny + m[2]) / (w == 0 ? 1 : w)
            let oy = (m[3]*nx + m[4]*ny + m[5]) / (w == 0 ? 1 : w)
            return CGPoint(x: ox * natSize.width, y: oy * natSize.height)
        }
        let ext = image.extent
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: warp(ext.minX, ext.maxY)),
            "inputTopRight": CIVector(cgPoint: warp(ext.maxX, ext.maxY)),
            "inputBottomRight": CIVector(cgPoint: warp(ext.maxX, ext.minY)),
            "inputBottomLeft": CIVector(cgPoint: warp(ext.minX, ext.minY)),
        ])
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Compositing/FrameRenderer.swift Sources/PalmierPro/Preview/
git commit -m "feat(stabilization): perspective mode via CIPerspectiveTransform"
```

---

## Task 8: Inspector UI + manual verification

**Files:**
- Create: `Sources/PalmierPro/Editor/Inspector/StabilizationInspectorSection.swift`
- Modify: clip inspector container (find with `rg -n "Inspector" Sources/PalmierPro/Editor/Inspector` or wherever effect/transform sections are mounted)

- [ ] **Step 1: Build the section**

`Sources/PalmierPro/Editor/Inspector/StabilizationInspectorSection.swift`:
```swift
import SwiftUI

struct StabilizationInspectorSection: View {
    @Bindable var editor: EditorViewModel
    let clip: Clip

    private var stab: Stabilization { clip.stabilization ?? Stabilization(enabled: false) }
    private var canStabilize: Bool { clip.mediaType == .video && clip.speed == 1.0 }
    private var analyzing: Double? { editor.stabilizationManager.progressByAsset[clip.mediaRef] }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Toggle("Stabilize", isOn: Binding(
                get: { clip.stabilization?.enabled ?? false },
                set: { on in update { $0.enabled = on }; if on { triggerAnalysis() } }))
                .disabled(!canStabilize)

            if clip.stabilization?.enabled == true {
                Picker("Method", selection: Binding(
                    get: { stab.method },
                    set: { v in update { $0.method = v } })) {
                    ForEach(StabMethod.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                HStack {
                    Text("Smoothness")
                    Slider(value: Binding(
                        get: { stab.smoothness },
                        set: { v in update { $0.smoothness = v } }), in: 0...1)
                }
                Toggle("Crop to fit", isOn: Binding(
                    get: { stab.cropToFit },
                    set: { v in update { $0.cropToFit = v } }))

                if let p = analyzing, p < 1 {
                    ProgressView(value: p) { Text("Analyzing… \(Int(p * 100))%") }
                        .font(.system(size: AppTheme.FontSize.xs))
                }
            }
            if !canStabilize {
                Text("Stabilization requires a video clip at normal speed.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
        }
    }

    private func update(_ mutate: (inout Stabilization) -> Void) {
        var s = clip.stabilization ?? Stabilization()
        mutate(&s)
        editor.updateClip(id: clip.id) { $0.stabilization = s }   // use the codebase's clip-mutation API
        editor.stabilizationManager.invalidateCache()
        editor.videoEngine?.rebuild()
    }

    private func triggerAnalysis() {
        guard !editor.stabilizationManager.hasAnalysis(assetId: clip.mediaRef),
              let url = editor.sourceURL(forMediaRef: clip.mediaRef) else { return }
        editor.stabilizationManager.analyze(assetId: clip.mediaRef, url: url)
    }
}
```

> Replace `editor.updateClip(id:)` and `editor.sourceURL(forMediaRef:)` with the actual clip-mutation and URL-resolution APIs used elsewhere in the inspector (check a neighboring section, e.g. the effects or transform inspector). Honor `AppTheme` for every spacing/font/color.

- [ ] **Step 2: Mount the section**

Add `StabilizationInspectorSection(editor: editor, clip: clip)` where the transform/effects sections are mounted in the clip inspector. Match surrounding layout.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Manual verification (required)**

Run: `./scripts/dev.sh`
- Import a shaky video clip, drop it on the timeline, select it.
- Toggle **Stabilize** on → analysis HUD/progress appears, then completes.
- Scrub playback: footage is visibly steadier; edges stay covered with **Crop to fit** on.
- Switch **Method** between Position / Similarity / Perspective → preview updates instantly (no re-analysis).
- Drag **Smoothness** → updates live.
- Confirm a non-video or sped-up clip shows the disabled state.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Editor/Inspector/StabilizationInspectorSection.swift Sources/PalmierPro/Editor/
git commit -m "feat(stabilization): clip-inspector controls and background analysis trigger"
```

---

## Task 9: Persistence sanity + full suite

- [ ] **Step 1: Verify project round-trip**

In the running app: enable stabilization on a clip, save the project, reopen it.
Expected: `Stabilization` params persist (in `project.json`); the sidecar
(`media/stabilization/<assetId>.json`) is present and reused without re-analysis.

- [ ] **Step 2: Run the full test suite**

Run: `swift test`
Expected: all suites pass, including `PathSmootherTests`, `StabilizationSidecarTests`, `StabilizationAnalyzerTests`.

- [ ] **Step 3: Final commit**

```bash
git commit --allow-empty -m "test(stabilization): verify full suite green"
```

---

## Self-Review Notes

- **Spec coverage:** analyzer (Task 4), smoother (Task 3), sidecar caching (Task 2/5), three modes (Tasks 6–7), inspector + HUD (Task 8), persistence (Task 9), error/fallback (analyzer translational fallback + identity-on-missing in manager/renderer). All spec sections mapped.
- **Deferred (per spec):** mesh/rolling-shutter, speed≠1 clips (disabled in UI), non-video clips (disabled).
- **Type consistency:** `StabFrameTransform`, `Stabilization`, `StabMethod`, `PathSmoother.Result`, `StabSidecar` used consistently across tasks; `normalizedHomographyToAffine` defined in Task 6 and reused; `corrections(for:assetURL:)` signature stable.
- **Known adaptation points (flagged inline):** exact Vision SDK symbols (Task 4), `LayerPlan` location/Sendable (Task 6), editor clip-mutation + URL-resolution APIs (Task 8). Each is a small, local lookup — not a design gap.
```
