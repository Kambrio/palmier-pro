# Proxy Media Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users edit heavy 6K footage smoothly by editing against on-demand ProRes 422 Proxy copies, while export always uses the original source.

**Architecture:** A `ProxyService` transcodes source clips to small ProRes 422 Proxy `.mov` files inside the project package (`media/proxies/<id>.mov`), tracked per-asset in the manifest. A global per-project `useProxies` flag makes the **preview** resolver return the proxy URL; export keeps the source-only resolver. Pixel-unit effect params are scaled by the proxy shrink factor so preview stays WYSIWYG.

**Tech Stack:** Swift 6.2, AVFoundation (`AVAssetReader`/`AVAssetWriter`, `AVVideoCodecType.proRes422Proxy`), CoreImage (frame scaling), SwiftUI/AppKit (menu + HUD), Swift Testing.

**Branch:** `proxy-media` (already created off `timeline-scroll-perf`; the design doc lives at `docs/superpowers/specs/2026-06-25-proxy-media-design.md`).

**Spec:** `docs/superpowers/specs/2026-06-25-proxy-media-design.md`

---

## File Structure

- Create `Sources/PalmierPro/Proxy/ProxyResolution.swift` — resolution enum.
- Create `Sources/PalmierPro/Proxy/ProxyService.swift` — single-asset transcode.
- Create `Sources/PalmierPro/Proxy/ProxyManager.swift` — queue, status, manifest wiring, invalidation.
- Create `Sources/PalmierPro/UI/ProxyProgressHUD.swift` — generation progress HUD.
- Modify `Sources/PalmierPro/Models/MediaManifest.swift` — `useProxies`, `proxyResolution`, `MediaManifestEntry.proxyPath`, `proxySourceSig`.
- Modify `Sources/PalmierPro/Utilities/Constants.swift` — `Project.proxiesDirname`.
- Modify `Sources/PalmierPro/Models/MediaResolver.swift` — `proxyURL(for:)`.
- Modify `Sources/PalmierPro/Models/MediaAsset.swift` — in-memory `proxyState`.
- Modify `Sources/PalmierPro/Compositing/CompositorInstruction.swift` — `LayerPlan.sourceNatSize`.
- Modify `Sources/PalmierPro/Preview/CompositionBuilder.swift` — populate `sourceNatSize`.
- Modify `Sources/PalmierPro/Compositing/FrameRenderer.swift` — pass `pixelScale` to effects.
- Modify `Sources/PalmierPro/Compositing/EffectRegistry.swift` — scale `unit == "px"` params.
- Modify `Sources/PalmierPro/Preview/VideoEngine.swift` — proxy-aware resolve closure.
- Modify `Sources/PalmierPro/Editor/ViewModel/EditorViewModel.swift` — `proxyManager`, toggle accessors.
- Modify `Sources/PalmierPro/Preview/PreviewContainerView.swift` — Proxies menu.
- Modify `Sources/PalmierPro/Project/VideoProject.swift` — copy `media/proxies/` on save.
- Tests under `Tests/PalmierProTests/Proxy/`.

---

## Task 1: Resolution model + manifest + package constant

**Files:**
- Create: `Sources/PalmierPro/Proxy/ProxyResolution.swift`
- Modify: `Sources/PalmierPro/Models/MediaManifest.swift`
- Modify: `Sources/PalmierPro/Utilities/Constants.swift` (after line 111)
- Test: `Tests/PalmierProTests/Proxy/ProxyResolutionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Proxy/ProxyResolutionTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("ProxyResolution")
struct ProxyResolutionTests {
    @Test func shortSidesAreStandard() {
        #expect(ProxyResolution.p240.shortSide == 240)
        #expect(ProxyResolution.p720.shortSide == 720)
        #expect(ProxyResolution.p1080.shortSide == 1080)
    }

    // Landscape 6144x3456 at 720p -> short side 720, long side 1280, even.
    @Test func targetSizePreservesAspectAndIsEven() {
        let s = ProxyResolution.p720.targetSize(forSource: CGSize(width: 6144, height: 3456))
        #expect(s.height == 720)
        #expect(s.width == 1280)
        #expect(Int(s.width) % 2 == 0 && Int(s.height) % 2 == 0)
    }

    // Never upscale: a 480-tall source stays 480 at 720p.
    @Test func neverUpscales() {
        let s = ProxyResolution.p720.targetSize(forSource: CGSize(width: 854, height: 480))
        #expect(s.height == 480)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProxyResolution`
Expected: FAIL — `ProxyResolution` not defined.

- [ ] **Step 3: Create `ProxyResolution.swift`**

```swift
// Sources/PalmierPro/Proxy/ProxyResolution.swift
import Foundation

/// Target proxy resolution, by short side. Aspect preserved; never upscaled.
enum ProxyResolution: String, CaseIterable, Sendable, Codable {
    case p240, p360, p480, p720, p1080

    var shortSide: Int {
        switch self {
        case .p240: 240
        case .p360: 360
        case .p480: 480
        case .p720: 720
        case .p1080: 1080
        }
    }

    var label: String { "\(shortSide)p" }

    /// Even, aspect-preserving size whose short side is `shortSide` (or the source's,
    /// whichever is smaller — proxies never upscale).
    func targetSize(forSource source: CGSize) -> CGSize {
        let w = source.width, h = source.height
        guard w > 0, h > 0 else { return source }
        let srcShort = min(w, h)
        let scale = min(1.0, Double(shortSide) / Double(srcShort))
        func even(_ v: Double) -> Int { let i = Int(v.rounded()); return max(2, i - (i % 2)) }
        return CGSize(width: even(Double(w) * scale), height: even(Double(h) * scale))
    }
}
```

- [ ] **Step 4: Add the package constant**

In `Sources/PalmierPro/Utilities/Constants.swift`, inside `enum Project`, after `manifestFilename` (line 111):

```swift
    /// Subdirectory of `media/` holding generated proxy movies.
    static let proxiesDirname = "proxies"
```

- [ ] **Step 5: Extend the manifest**

In `Sources/PalmierPro/Models/MediaManifest.swift`, add fields + decode. Replace the `MediaManifest` struct body's stored props and `init(from:)`/`CodingKeys` with:

```swift
struct MediaManifest: Codable, Sendable, Equatable {
    var version: Int = 2
    var entries: [MediaManifestEntry] = []
    var folders: [MediaFolder] = []
    var useProxies: Bool = false
    var proxyResolution: ProxyResolution = .p720

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([MediaManifestEntry].self, forKey: .entries) ?? []
        folders = try c.decodeIfPresent([MediaFolder].self, forKey: .folders) ?? []
        useProxies = try c.decodeIfPresent(Bool.self, forKey: .useProxies) ?? false
        proxyResolution = try c.decodeIfPresent(ProxyResolution.self, forKey: .proxyResolution) ?? .p720
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, entries, folders, useProxies, proxyResolution
    }
}
```

In `MediaManifestEntry`, add after `cachedRemoteURLExpiresAt`:

```swift
    /// Relative path (within the package) of the generated proxy, if any.
    var proxyPath: String?
    /// Source identity (mtime+size hash) the proxy was built from; for staleness checks.
    var proxySourceSig: String?
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ProxyResolution`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/PalmierPro/Proxy/ProxyResolution.swift Sources/PalmierPro/Models/MediaManifest.swift Sources/PalmierPro/Utilities/Constants.swift Tests/PalmierProTests/Proxy/ProxyResolutionTests.swift
git commit -m "feat(proxy): resolution model + manifest fields + package constant"
```

---

## Task 2: Source identity signature

**Files:**
- Create: `Sources/PalmierPro/Proxy/ProxySignature.swift`
- Test: `Tests/PalmierProTests/Proxy/ProxySignatureTests.swift`

Mirrors the `mtime+size` identity used by `TranscriptCache.key`. Used to detect when a source changed so its proxy is regenerated.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Proxy/ProxySignatureTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("ProxySignature")
struct ProxySignatureTests {
    @Test func stableForSameFileAndChangesWithContent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: url)
        let s1 = ProxySignature.of(url)
        #expect(s1 != nil)
        #expect(ProxySignature.of(url) == s1)            // stable
        try Data([1, 2, 3, 4, 5]).write(to: url)         // size change
        #expect(ProxySignature.of(url) != s1)
    }

    @Test func nilForMissingFile() {
        #expect(ProxySignature.of(URL(fileURLWithPath: "/no/such/file.mov")) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProxySignature`
Expected: FAIL — `ProxySignature` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/PalmierPro/Proxy/ProxySignature.swift
import Foundation
import CryptoKit

enum ProxySignature {
    /// `mtime|size` hashed to a short hex string; nil if the file is unreadable.
    static func of(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        let identity = "\(mtime.timeIntervalSince1970)|\(size)"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProxySignature`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Proxy/ProxySignature.swift Tests/PalmierProTests/Proxy/ProxySignatureTests.swift
git commit -m "feat(proxy): source identity signature for staleness checks"
```

---

## Task 3: ProxyService — transcode one asset to ProRes 422 Proxy

**Files:**
- Create: `Sources/PalmierPro/Proxy/ProxyService.swift`
- Test: `Tests/PalmierProTests/Proxy/ProxyServiceTests.swift`

Uses `AVAssetReader` (decompress) → CoreImage scale → `AVAssetWriter` (`.proRes422Proxy`). Audio re-encoded to AAC. Reports progress; honors cancellation.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Proxy/ProxyServiceTests.swift
import AVFoundation
import Testing
@testable import PalmierPro

@Suite("ProxyService")
struct ProxyServiceTests {
    // Build a tiny 1280x720 source, transcode to 360p proxy, assert codec + size.
    @Test func transcodesToProResProxyAtTargetShortSide() async throws {
        let src = try await CompositorFixtures.makeSolidVideo(width: 1280, height: 720, seconds: 1)
        defer { try? FileManager.default.removeItem(at: src) }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }

        try await ProxyService.transcode(source: src, to: out, resolution: .p360) { _ in }

        let asset = AVURLAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize)
        #expect(size?.height == 360)
        #expect(size?.width == 640)
        let formats = try await track?.load(.formatDescriptions) ?? []
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(codec == kCMVideoCodecType_AppleProRes422Proxy)
    }
}
```

> Note: `CompositorFixtures` already exists at `Tests/PalmierProTests/Rendering/CompositorFixtures.swift`. If it lacks `makeSolidVideo`, add a helper there that writes a short solid-color H.264 mov with `AVAssetWriter` and returns its URL (see existing fixture helpers in that file for the writer setup pattern).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProxyService`
Expected: FAIL — `ProxyService` not defined (or `makeSolidVideo` missing — add it first).

- [ ] **Step 3: Implement `ProxyService`**

```swift
// Sources/PalmierPro/Proxy/ProxyService.swift
import AVFoundation
import CoreImage

enum ProxyService {
    struct Failure: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    /// Transcodes `source` to a ProRes 422 Proxy `.mov` at `to`, scaled so its short
    /// side is `resolution.shortSide` (never upscaled). `progress` is called on an
    /// arbitrary thread with 0...1. Throws `CancellationError` if the task is cancelled.
    static func transcode(
        source: URL,
        to output: URL,
        resolution: ProxyResolution,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(reason: "source has no video track")
        }
        let srcSize = try await videoTrack.load(.naturalSize).applying(
            try await videoTrack.load(.preferredTransform)
        )
        let absSize = CGSize(width: abs(srcSize.width), height: abs(srcSize.height))
        let target = resolution.targetSize(forSource: absSize)
        let duration = try await asset.load(.duration)

        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)

        // --- Video: decompress to BGRA, scale with CIContext, encode ProRes Proxy.
        let readerVideo = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerVideo.alwaysCopiesSampleData = false
        reader.add(readerVideo)

        let writerVideo = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422Proxy,
            AVVideoWidthKey: Int(target.width),
            AVVideoHeightKey: Int(target.height),
        ])
        writerVideo.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerVideo,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(target.width),
                kCVPixelBufferHeightKey as String: Int(target.height),
            ]
        )
        writer.add(writerVideo)

        // --- Audio (optional): decompress to LPCM, re-encode AAC.
        var readerAudio: AVAssetReaderTrackOutput?
        var writerAudio: AVAssetWriterInput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let ra = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(ra); readerAudio = ra
            let wa = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100, AVEncoderBitRateKey: 128_000,
            ])
            wa.expectsMediaDataInRealTime = false
            writer.add(wa); writerAudio = wa
        }

        guard reader.startReading() else { throw Failure(reason: reader.error?.localizedDescription ?? "reader failed") }
        guard writer.startWriting() else { throw Failure(reason: writer.error?.localizedDescription ?? "writer failed") }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext()
        let scaleX = target.width / absSize.width
        let scaleY = target.height / absSize.height

        // Video pass.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "io.palmier.proxy.video")
            writerVideo.requestMediaDataWhenReady(on: queue) {
                while writerVideo.isReadyForMoreMediaData {
                    if Task.isCancelled { reader.cancelReading(); writer.cancelWriting(); cont.resume(throwing: CancellationError()); return }
                    guard let sample = readerVideo.copyNextSampleBuffer(),
                          let src = CMSampleBufferGetImageBuffer(sample) else {
                        writerVideo.markAsFinished(); cont.resume(); return
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    var outBuf: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &outBuf)
                    if let outBuf {
                        let img = CIImage(cvPixelBuffer: src)
                            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                        ciContext.render(img, to: outBuf)
                        adaptor.append(outBuf, withPresentationTime: time)
                    }
                    if duration.seconds > 0 { progress(min(1, time.seconds / duration.seconds)) }
                }
            }
        }

        // Audio pass (sequential; small).
        if let readerAudio, let writerAudio {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "io.palmier.proxy.audio")
                writerAudio.requestMediaDataWhenReady(on: queue) {
                    while writerAudio.isReadyForMoreMediaData {
                        if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                        guard let sample = readerAudio.copyNextSampleBuffer() else {
                            writerAudio.markAsFinished(); cont.resume(); return
                        }
                        writerAudio.append(sample)
                    }
                }
            }
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw Failure(reason: writer.error?.localizedDescription ?? "writer did not complete")
        }
        progress(1)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProxyService`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Proxy/ProxyService.swift Tests/PalmierProTests/Proxy/ProxyServiceTests.swift Tests/PalmierProTests/Rendering/CompositorFixtures.swift
git commit -m "feat(proxy): ProResProxy transcode service (AVAssetReader/Writer + CI scale)"
```

---

## Task 4: MediaResolver proxy lookup + per-asset state

**Files:**
- Modify: `Sources/PalmierPro/Models/MediaResolver.swift`
- Modify: `Sources/PalmierPro/Models/MediaAsset.swift`
- Test: `Tests/PalmierProTests/Proxy/ProxyResolveTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Proxy/ProxyResolveTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("MediaResolver — proxy lookup")
struct ProxyResolveTests {
    @Test func proxyURLReturnsFileWhenPresentElseNil() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("media/proxies"), withIntermediateDirectories: true)
        let proxy = base.appendingPathComponent("media/proxies/asset1.mov")
        try Data([0]).write(to: proxy)

        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "asset1", name: "a", type: .video,
            source: .project(relativePath: "media/asset1.mov"), duration: 1,
            proxyPath: "media/proxies/asset1.mov")]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { base })

        #expect(resolver.proxyURL(for: "asset1") == proxy)
        #expect(resolver.proxyURL(for: "missing") == nil)
    }
}
```

> `MediaManifestEntry` is memberwise-initialized; supply the new fields' defaults as needed. If the memberwise init isn't visible from tests, add an explicit `init` to `MediaManifestEntry` mirroring its stored properties.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "MediaResolver — proxy"`
Expected: FAIL — `proxyURL(for:)` not defined.

- [ ] **Step 3: Implement `proxyURL` in `MediaResolver`**

Add to `MediaResolver` (after `expectedURL`):

```swift
    /// Resolved on-disk URL of an asset's proxy, if the manifest records one and the
    /// file exists. Project-relative; nil otherwise. Preview-only — never used by export.
    func proxyURL(for assetId: String) -> URL? {
        guard let rel = entry(for: assetId)?.proxyPath, let base = projectURL() else { return nil }
        let url = base.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
```

- [ ] **Step 4: Add in-memory proxy state to `MediaAsset`**

In `Sources/PalmierPro/Models/MediaAsset.swift`, add (near `generationStatus`):

```swift
    enum ProxyState: Equatable { case none, generating(Double), ready, failed(String) }
    var proxyState: ProxyState = .none
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter "MediaResolver — proxy"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Models/MediaResolver.swift Sources/PalmierPro/Models/MediaAsset.swift Tests/PalmierProTests/Proxy/ProxyResolveTests.swift
git commit -m "feat(proxy): MediaResolver.proxyURL + per-asset proxy state"
```

---

## Task 5: Proxy-aware preview resolve in VideoEngine

**Files:**
- Modify: `Sources/PalmierPro/Preview/VideoEngine.swift:155-165` (the `rebuild()` resolver closure)

Export already uses `resolver.resolveURL` directly (`ExportService.swift:217`) and is untouched. Only the preview composition prefers the proxy.

- [ ] **Step 1: Change the preview resolver closure**

In `VideoEngine.rebuild()`, replace:

```swift
        let resolver = editor.mediaResolver
        let renderSize = previewRenderSize
```

with:

```swift
        let resolver = editor.mediaResolver
        let useProxies = editor.mediaManifest.useProxies
        let renderSize = previewRenderSize
```

and replace the `resolveURL:` argument in the `CompositionBuilder.build(...)` call:

```swift
                    resolveURL: { resolver.resolveURL(for: $0) },
```

with:

```swift
                    resolveURL: { id in
                        (useProxies ? resolver.proxyURL(for: id) : nil) ?? resolver.resolveURL(for: id)
                    },
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Preview/VideoEngine.swift
git commit -m "feat(proxy): preview composition prefers proxy when useProxies is on"
```

---

## Task 6: Effect pixel-param scaling (WYSIWYG)

**Files:**
- Modify: `Sources/PalmierPro/Compositing/CompositorInstruction.swift:4-10` (`LayerPlan`)
- Modify: `Sources/PalmierPro/Preview/CompositionBuilder.swift` (populate `sourceNatSize`)
- Modify: `Sources/PalmierPro/Compositing/EffectRegistry.swift` (`render` gains `pixelScale`)
- Modify: `Sources/PalmierPro/Compositing/FrameRenderer.swift:74-80` (pass `pixelScale`)
- Test: `Tests/PalmierProTests/Proxy/EffectPixelScaleTests.swift`

Effects render in source-pixel space (`FrameRenderer.swift:73`). On a proxy (smaller decoded frame) a px-unit radius must scale **down** by `proxyLong / sourceLong` to cover the same fraction of frame.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Proxy/EffectPixelScaleTests.swift
import CoreImage
import Testing
@testable import PalmierPro

@Suite("Effect pixel scaling")
struct EffectPixelScaleTests {
    // A px-unit param (blur radius) is multiplied by pixelScale; a unitless param is not.
    @Test func pxParamsScaleUnitlessDoNot() {
        guard let blur = EffectRegistry.descriptor(id: "blur.gaussian") else { Issue.record("no blur"); return }
        let spec = blur.params.first { $0.unit == "px" }
        #expect(spec != nil, "blur should have a px param")

        let img = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        var e = blur.makeEffect()
        e.params[spec!.key] = EffectParam(value: 40)
        // Full vs half scale should differ (more blur at scale 1 than 0.5).
        let full = blur.render(img, effect: e, atOffset: 0, pixelScale: 1).clampedToExtent()
        let half = blur.render(img, effect: e, atOffset: 0, pixelScale: 0.5).clampedToExtent()
        // Same input, different effective radius => different extents after clamp/blur.
        #expect(full.extent != half.extent || full != half)
    }
}
```

> If `blur.gaussian` isn't the exact id, use `EffectRegistry.all.first { d in d.params.contains { $0.unit == "px" } }!.id`. Keep the assertion behavioral (scale changes output).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "Effect pixel scaling"`
Expected: FAIL — `render(_:effect:atOffset:pixelScale:)` has no `pixelScale` parameter.

- [ ] **Step 3: Add `pixelScale` to `EffectDescriptor.render`**

In `EffectRegistry.swift`, replace `render(_:effect:atOffset:)` (lines 63-75) with:

```swift
    /// Full application incl. optional linear-light wrapping. `pixelScale` (≤ 1 when
    /// rendering a proxy) scales px-unit params so spatial effects match the source.
    func render(_ image: CIImage, effect: Effect, atOffset offset: Int, pixelScale: CGFloat = 1) -> CIImage {
        var params = resolve(effect, atOffset: offset)
        if pixelScale != 1 {
            var values = params.values
            for spec in self.params where spec.unit == "px" {
                values[spec.key] = (values[spec.key] ?? spec.defaultValue) * Double(pixelScale)
            }
            params = ResolvedEffectParams(values: values, strings: params.strings, frame: offset)
        }
        let extent = image.extent
        var working = image
        if linearizes { working = working.applyingFilter("CISRGBToneCurveToLinear") }
        working = apply(working, params, extent)
        if linearizes { working = working.applyingFilter("CILinearToSRGBToneCurve") }
        return working
    }
```

- [ ] **Step 4: Add `sourceNatSize` to `LayerPlan`**

In `Sources/PalmierPro/Compositing/CompositorInstruction.swift`, change `LayerPlan` to:

```swift
struct LayerPlan: Sendable {
    let trackID: CMPersistentTrackID
    let clip: Clip
    /// Display size (preferredTransform applied) of the *decoded* frame (proxy when proxied).
    let natSize: CGSize
    /// Display size of the original source; equals `natSize` when not proxied.
    let sourceNatSize: CGSize
    let preferredTransform: CGAffineTransform
}
```

- [ ] **Step 5: Populate `sourceNatSize` in `CompositionBuilder`**

In `Sources/PalmierPro/Preview/CompositionBuilder.swift`, in `compositorInstructions(...)`, where `LayerPlan(...)` is constructed (around line 467-472), pass the source size from `clipNaturalSizes`/`resolveSourceSize`. Since `compositorInstructions` already has `clipNaturalSizes` (the decoded sizes) and the builder has `resolveSourceSize`, thread a `sourceSizes: [String: CGSize]` parameter built in `build(...)` from `resolveSourceSize(clip.mediaRef)`, and set:

```swift
                    plan: LayerPlan(
                        trackID: mapping.compositionTrack.trackID,
                        clip: clip,
                        natSize: clipNaturalSizes[clip.id] ?? mapping.naturalSize,
                        sourceNatSize: sourceSizes[clip.id] ?? clipNaturalSizes[clip.id] ?? mapping.naturalSize,
                        preferredTransform: clipTransforms[clip.id] ?? .identity
                    )
```

Build `sourceSizes` in `build(...)` alongside `clipNaturalSizes`: for each inserted clip, `sourceSizes[clip.id] = resolveSourceSize(clip.mediaRef).map { abs-size } ?? clipNaturalSizes[clip.id]`. Pass `sourceSizes` into `buildVisuals` → `compositorInstructions` (add the parameter to both signatures, default `[:]`).

- [ ] **Step 6: Pass `pixelScale` in `FrameRenderer`**

In `Sources/PalmierPro/Compositing/FrameRenderer.swift`, replace the effects loop (lines 74-80) with:

```swift
        if let effects = clip.effects, !effects.isEmpty {
            let offset = frame - clip.startFrame
            // Proxy frames are smaller; scale px-unit effect params so spatial effects
            // cover the same fraction of frame as on the full-res source.
            let srcLong = max(layer.sourceNatSize.width, layer.sourceNatSize.height)
            let decLong = max(layer.natSize.width, layer.natSize.height)
            let pixelScale = srcLong > 0 ? min(1, decLong / srcLong) : 1
            for effect in effects where effect.enabled {
                guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
                image = descriptor.render(image, effect: effect, atOffset: offset, pixelScale: pixelScale)
            }
        }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter "Effect pixel scaling"` then `swift test --filter "Compositor"`
Expected: PASS (new test + existing compositor suite still green).

- [ ] **Step 8: Commit**

```bash
git add Sources/PalmierPro/Compositing/EffectRegistry.swift Sources/PalmierPro/Compositing/CompositorInstruction.swift Sources/PalmierPro/Compositing/FrameRenderer.swift Sources/PalmierPro/Preview/CompositionBuilder.swift Tests/PalmierProTests/Proxy/EffectPixelScaleTests.swift
git commit -m "feat(proxy): scale px-unit effect params by proxy ratio for WYSIWYG"
```

---

## Task 7: ProxyManager — queue, status, manifest wiring

**Files:**
- Create: `Sources/PalmierPro/Proxy/ProxyManager.swift`
- Modify: `Sources/PalmierPro/Editor/ViewModel/EditorViewModel.swift` (add `proxyManager`, toggle accessors)
- Test: `Tests/PalmierProTests/Proxy/ProxyManagerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Proxy/ProxyManagerTests.swift
import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("ProxyManager")
struct ProxyManagerTests {
    // Assets needing proxies = video assets without a current (matching-sig) proxy.
    @Test func assetsNeedingProxiesExcludesReadyAndNonVideo() async throws {
        let editor = EditorViewModel()
        let v = MediaAsset(id: "v", url: URL(fileURLWithPath: "/tmp/v.mov"), type: .video, name: "v", duration: 1)
        let a = MediaAsset(id: "a", url: URL(fileURLWithPath: "/tmp/a.m4a"), type: .audio, name: "a", duration: 1)
        editor.importMediaAsset(v)
        editor.importMediaAsset(a)
        let mgr = ProxyManager(editor: editor)

        let need = mgr.assetsNeedingProxies()
        #expect(need.map(\.id) == ["v"])   // audio excluded, video has no proxy yet
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProxyManager`
Expected: FAIL — `ProxyManager` not defined.

- [ ] **Step 3: Implement `ProxyManager`**

```swift
// Sources/PalmierPro/Proxy/ProxyManager.swift
import Foundation
import AVFoundation

@MainActor
final class ProxyManager {
    private unowned let editor: EditorViewModel
    private static let gate = AsyncSemaphore(value: 2)
    private(set) var isGenerating = false
    private(set) var completed = 0
    private(set) var total = 0
    private var job: Task<Void, Never>?

    init(editor: EditorViewModel) { self.editor = editor }

    /// Video assets that lack a current proxy (none, failed, or source changed).
    func assetsNeedingProxies() -> [MediaAsset] {
        editor.mediaAssets.filter { asset in
            guard asset.type == .video else { return false }
            return !hasCurrentProxy(asset)
        }
    }

    private func hasCurrentProxy(_ asset: MediaAsset) -> Bool {
        guard let entry = editor.mediaManifest.entries.first(where: { $0.id == asset.id }),
              let rel = entry.proxyPath, let base = editor.projectURL else { return false }
        let url = base.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return entry.proxySourceSig == nil || entry.proxySourceSig == ProxySignature.of(asset.url)
    }

    /// Background-generate proxies for all assets that need them. No-op if running or
    /// the project isn't saved (proxies live in the package).
    func createProxies() {
        guard !isGenerating, let base = editor.projectURL else { return }
        let targets = assetsNeedingProxies()
        guard !targets.isEmpty else { return }
        let resolution = editor.mediaManifest.proxyResolution
        let proxiesDir = base.appendingPathComponent("\(Project.mediaDirectoryName)/\(Project.proxiesDirname)", isDirectory: true)

        isGenerating = true; completed = 0; total = targets.count
        job = Task { [weak self] in
            try? FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)
            await withTaskGroup(of: Void.self) { group in
                for asset in targets {
                    group.addTask { await self?.generateOne(asset, into: proxiesDir, resolution: resolution) }
                }
                await group.waitForAll()
            }
            await MainActor.run { self?.isGenerating = false }
        }
    }

    func cancel() { job?.cancel(); job = nil; isGenerating = false }

    private func generateOne(_ asset: MediaAsset, into dir: URL, resolution: ProxyResolution) async {
        guard (try? await Self.gate.wait()) != nil else { return }
        defer { Task { await Self.gate.signal() } }
        await MainActor.run { asset.proxyState = .generating(0) }
        let out = dir.appendingPathComponent("\(asset.id).mov")
        let rel = "\(Project.mediaDirectoryName)/\(Project.proxiesDirname)/\(asset.id).mov"
        do {
            try await ProxyService.transcode(source: asset.url, to: out, resolution: resolution) { p in
                Task { @MainActor in asset.proxyState = .generating(p) }
            }
            let sig = ProxySignature.of(asset.url)
            await MainActor.run {
                asset.proxyState = .ready
                if let i = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                    editor.mediaManifest.entries[i].proxyPath = rel
                    editor.mediaManifest.entries[i].proxySourceSig = sig
                }
                completed += 1
                if editor.mediaManifest.useProxies { editor.videoEngine?.rebuild() }
            }
        } catch {
            await MainActor.run { asset.proxyState = .failed(error.localizedDescription); completed += 1 }
        }
    }
}
```

> Confirmed: the package media directory constant is `Project.mediaDirectoryName` (`"media"`), used above.

- [ ] **Step 4: Wire `ProxyManager` + toggle accessors into `EditorViewModel`**

In `EditorViewModel.swift`, add (near `videoEngine`):

```swift
    lazy var proxyManager = ProxyManager(editor: self)

    var useProxies: Bool {
        get { mediaManifest.useProxies }
        set { guard newValue != mediaManifest.useProxies else { return }
              mediaManifest.useProxies = newValue; videoEngine?.rebuild() }
    }
    var proxyResolution: ProxyResolution {
        get { mediaManifest.proxyResolution }
        set { mediaManifest.proxyResolution = newValue }
    }
```

> Confirm `mediaManifest` is an observable stored property on `EditorViewModel` (it's encoded in `captureSaveSnapshot`). If mutating it doesn't persist, ensure these setters mutate `editor.mediaManifest` directly (they do) so autosave picks it up.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ProxyManager`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Proxy/ProxyManager.swift Sources/PalmierPro/Editor/ViewModel/EditorViewModel.swift Tests/PalmierProTests/Proxy/ProxyManagerTests.swift
git commit -m "feat(proxy): ProxyManager queue + status + toggle accessors"
```

---

## Task 8: Verify proxies persist in the package (no code expected)

**Files:** none expected.

`writeProjectPackage` copies the whole media directory via
`copyDirectoryIfNeeded(Project.mediaDirectoryName, ...)` (`VideoProject.swift:195`).
Since proxies live at `media/proxies/`, they are inside that directory and travel with
every safe-save automatically — no code change required.

- [ ] **Step 1: Confirm the whole-directory copy**

Run: `grep -n "copyDirectoryIfNeeded(Project.mediaDirectoryName" Sources/PalmierPro/Project/VideoProject.swift`
Expected: one call in `writeProjectPackage`; `media/proxies/` is carried by it.
(Persistence is exercised in Task 10's reopen check.) No commit for this task.

---

## Task 9: UI — Proxies menu + progress HUD

**Files:**
- Create: `Sources/PalmierPro/UI/ProxyProgressHUD.swift`
- Modify: `Sources/PalmierPro/Preview/PreviewContainerView.swift` (add menu next to quality menu)
- Modify: `Sources/PalmierPro/Project/VideoProject.swift` (mount the HUD overlay, mirroring `MediaLoadHUD`)

- [ ] **Step 1: Add the Proxies menu to the transport bar**

In `PreviewContainerView.swift`, in `transportBar`, after the preview-quality `settingsMenuButton` and before the zoom button, add:

```swift
            if isTimeline {
                Menu {
                    Toggle("Use Proxies", isOn: Binding(
                        get: { editor.useProxies }, set: { editor.useProxies = $0 }))
                    Menu("Proxy Resolution") {
                        ForEach(ProxyResolution.allCases, id: \.self) { res in
                            Button {
                                editor.proxyResolution = res
                            } label: {
                                HStack {
                                    Text(res.label)
                                    Spacer()
                                    if editor.proxyResolution == res { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    Divider()
                    Button(proxyActionLabel) { editor.proxyManager.createProxies() }
                        .disabled(editor.proxyManager.isGenerating || editor.proxyManager.assetsNeedingProxies().isEmpty)
                } label: {
                    badgeLabel(editor.useProxies ? "Proxy" : "Src")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHighlight()
                .help("Proxy media — edit lighter copies; export always uses source")
            }
```

Add the helper to `PreviewContainerView`:

```swift
    private var proxyActionLabel: String {
        let n = editor.proxyManager.assetsNeedingProxies().count
        return n == 0 ? "Proxies Ready" : "Create Proxies (\(n))"
    }
```

- [ ] **Step 2: Create the progress HUD**

```swift
// Sources/PalmierPro/UI/ProxyProgressHUD.swift
import SwiftUI

/// Bottom-corner progress for on-demand proxy generation. Mirrors MediaLoadHUD.
struct ProxyProgressHUD: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if editor.proxyManager.isGenerating {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Creating proxies — \(editor.proxyManager.completed) of \(editor.proxyManager.total)")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Button("Cancel") { editor.proxyManager.cancel() }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.md).strokeBorder(AppTheme.Border.subtleColor))
            )
            .shadow(AppTheme.Shadow.md)
            .padding(AppTheme.Spacing.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
```

> For `isGenerating`/`completed`/`total` to drive the view, mark them observable. `ProxyManager` is a plain class; make it `@Observable` (add `import Observation`/`@Observable` to the class) so SwiftUI tracks these properties. Verify the `@MainActor @Observable` combination compiles (the codebase uses it on `MediaAsset`).

- [ ] **Step 3: Mount the HUD**

In `VideoProject.swift`, next to the `MediaLoadHUD()` overlay (the `.overlay(alignment: .bottomTrailing)` near line 327 on this branch), add another overlay:

```swift
            .overlay(alignment: .bottomLeading) {
                ProxyProgressHUD()
                    .environment(editorViewModel)
            }
            .animation(.default, value: editorViewModel.proxyManager.isGenerating)
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/UI/ProxyProgressHUD.swift Sources/PalmierPro/Preview/PreviewContainerView.swift Sources/PalmierPro/Project/VideoProject.swift
git commit -m "feat(proxy): Proxies menu (toggle/resolution/create) + progress HUD"
```

---

## Task 10: Manual verification

**Files:** none (manual)

- [ ] **Step 1: Build + bundle + launch**

```bash
./scripts/bundle.sh debug && open .build/PalmierPro.app
```

- [ ] **Step 2: Verify on a 6K project**
- Open a 6K project; the preview bar shows a `Src` badge (proxies off).
- Proxies menu → Proxy Resolution → 720p → Create Proxies; the HUD shows progress and clears.
- Toggle Use Proxies on (badge → `Proxy`); playback/scrub is noticeably lighter.
- Apply a Gaussian Blur to a clip; confirm the blur looks the same with proxies on vs off (WYSIWYG).
- Export a short range; confirm the export is full-resolution (proxies never affect output).
- Save, reopen the project; proxies persist (no regeneration needed) and the toggle/resolution are remembered.

- [ ] **Step 3: Final full-suite run**

Run: `swift test`
Expected: All suites pass.

---

## Self-Review notes (addressed)
- **Spec coverage:** model+persistence (T1), invalidation sig (T2), transcode (T3), resolve swap (T4–T5), effect WYSIWYG (T6), queue/status (T7), package persistence (T8), UI+HUD (T9), analysis-from-source is satisfied because scopes/search/thumbnails call `resolver.resolveURL`/`asset.url` directly and were not pointed at proxies. ✅
- **Open verification points flagged inline** (media-dir constant name in T7/T8; memberwise init visibility in T4; `@Observable` on `ProxyManager` in T9) — the executor must confirm these against the code, not guess.
