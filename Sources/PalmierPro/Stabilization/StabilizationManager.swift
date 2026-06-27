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
    private var pending: [(assetId: String, url: URL)] = []
    private var running: String?
    /// In-memory cache of correction results keyed by clip + params.
    @ObservationIgnored private var correctionCache: [String: PathSmoother.Result] = [:]

    // MARK: - Bake queue (ffmpeg engine)

    /// assetId → bake progress (0…1).
    private(set) var bakeProgress: [String: Double] = [:]
    private var pendingBakes: [(assetId: String, url: URL, smoothness: Double)] = []
    private var runningBake: String?
    private var bakeJob: Task<Void, Never>?

    // MARK: - Subject-tracking queue

    private var pendingSubject: [(assetId: String, url: URL)] = []
    private var runningSubject: String?
    private var subjectJob: Task<Void, Never>?

    init(editor: EditorViewModel) { self.editor = editor }

    private var baseDir: URL? { editor.projectURL }

    private var stabilizedDir: URL? {
        editor.projectURL?.appendingPathComponent(
            "\(Project.mediaDirectoryName)/\(Project.stabilizedDirname)", isDirectory: true)
    }

    // MARK: - Bake helpers

    /// Returns the path of a baked stabilized movie if it exists and matches the source identity.
    /// Preview bake resolution context: proxy-res when proxies are on, else source. Part of the sig
    /// so toggling proxies (or preview quality) invalidates a mismatched-resolution bake.
    private var previewResTag: String { editor.mediaManifest.useProxies ? "proxy" : "src" }

    /// The preview bake URL, but only if it matches the CURRENT proxy state — otherwise nil so the
    /// renderer falls back to source (and reconcile re-bakes at the right resolution).
    func stabilizedURL(for assetId: String) -> URL? {
        guard let dir = stabilizedDir,
              let sourceURL = editor.mediaAssetsById[assetId]?.url,
              let sourceSig = ProxySignature.of(sourceURL) else { return nil }
        let mov = dir.appendingPathComponent("\(assetId).mov")
        let sig = dir.appendingPathComponent("\(assetId).sig")
        guard FileManager.default.fileExists(atPath: mov.path),
              let stored = try? String(contentsOf: sig, encoding: .utf8),
              stored.hasPrefix(sourceSig + "|"), stored.hasSuffix("|\(previewResTag)") else { return nil }
        return mov
    }

    /// True if the sig matches `sourceSig|smoothness|capability|resTag` — re-bakes when smoothness,
    /// the ffmpeg capability (deshake→vidstab), OR the proxy state (proxy-res↔source-res) changes.
    private func hasCurrentBake(assetId: String, smoothness: Double) -> Bool {
        guard let dir = stabilizedDir,
              let sourceURL = editor.mediaAssetsById[assetId]?.url,
              let sourceSig = ProxySignature.of(sourceURL) else { return false }
        let sig = dir.appendingPathComponent("\(assetId).sig")
        guard let stored = try? String(contentsOf: sig, encoding: .utf8) else { return false }
        return stored == "\(sourceSig)|\(smoothness)|\(VidStab.capability)|\(previewResTag)"
    }

    /// Enqueue a bake if not already current, running, or pending for this asset.
    func enqueueBake(assetId: String, url: URL, smoothness: Double) {
        guard stabilizedDir != nil else { return }
        if hasCurrentBake(assetId: assetId, smoothness: smoothness) { return }
        if runningBake == assetId || pendingBakes.contains(where: { $0.assetId == assetId }) { return }
        pendingBakes.append((assetId, url, smoothness))
        if bakeJob == nil { startBakeDraining() }
    }

    private func startBakeDraining() {
        bakeJob = Task { [weak self] in
            while let next = self?.dequeueBake() {
                self?.runningBake = next.assetId
                await self?.runBake(assetId: next.assetId, url: next.url, smoothness: next.smoothness)
                self?.runningBake = nil
            }
            self?.bakeJob = nil
        }
    }

    private func dequeueBake() -> (assetId: String, url: URL, smoothness: Double)? {
        guard !pendingBakes.isEmpty else { return nil }
        return pendingBakes.removeFirst()
    }

    private func runBake(assetId: String, url: URL, smoothness: Double) async {
        guard let dir = stabilizedDir,
              let ffmpeg = VidStab.ffmpegPath() else { return }
        let cap = VidStab.capability
        guard cap != .none else { return }
        bakeProgress[assetId] = 0
        let output = dir.appendingPathComponent("\(assetId).mov")
        let sigFile = dir.appendingPathComponent("\(assetId).sig")
        // Bake from the low-res proxy when proxies are on (seconds + a few MB vs minutes/GB on 6K
        // source); else bake from source but cap the long edge so it stays fast and small.
        let proxy = editor.mediaManifest.useProxies ? editor.mediaResolver.proxyURL(for: assetId) : nil
        let input = proxy ?? url
        let maxLongEdge = proxy == nil ? 1280 : 0
        let resTag = proxy != nil ? "proxy" : "src"
        do {
            try await FFmpegStabService.stabilize(
                source: input, to: output, smoothness: smoothness, maxLongEdge: maxLongEdge,
                capability: cap, ffmpeg: ffmpeg) { p in
                    Task { @MainActor [weak self] in self?.bakeProgress[assetId] = p }
                }
            // Write sidecar sig (sourceSig|smoothness|capability|resTag) after successful bake.
            if let sourceSig = ProxySignature.of(url) {
                try? "\(sourceSig)|\(smoothness)|\(cap)|\(resTag)".write(to: sigFile, atomically: true, encoding: .utf8)
            }
            bakeProgress[assetId] = 1
            editor.onPersistentStateChanged?()
            editor.videoEngine?.rebuild()
        } catch is CancellationError {
            bakeProgress[assetId] = nil
        } catch {
            Log.proxy.error("ffmpeg stab bake failed id=\(assetId.prefix(8)): \(Log.detail(error))")
            bakeProgress[assetId] = nil
        }
    }

    /// Ensure a FULL-quality stabilized file baked from the SOURCE (not the proxy) at `longEdge`
    /// exists for export, generating it synchronously if missing. The preview bake is proxy-res and
    /// too soft for final output; this is the correct full-res pass. Returns the file URL or nil.
    func ensureExportBake(assetId: String, smoothness: Double, longEdge: Int) async -> URL? {
        guard let dir = stabilizedDir,
              let source = editor.mediaAssetsById[assetId]?.url,
              let ffmpeg = VidStab.ffmpegPath() else { return nil }
        let cap = VidStab.capability
        guard cap != .none else { return nil }
        let output = dir.appendingPathComponent("\(assetId).full.mov")
        let sigFile = dir.appendingPathComponent("\(assetId).full.sig")
        let wantSig = "\(ProxySignature.of(source) ?? "")|\(smoothness)|\(cap)|\(longEdge)"
        if FileManager.default.fileExists(atPath: output.path),
           let stored = try? String(contentsOf: sigFile, encoding: .utf8), stored == wantSig {
            return output
        }
        do {
            bakeProgress[assetId] = 0
            try await FFmpegStabService.stabilize(
                source: source, to: output, smoothness: smoothness, maxLongEdge: longEdge,
                capability: cap, ffmpeg: ffmpeg) { p in
                    Task { @MainActor [weak self] in self?.bakeProgress[assetId] = p }
                }
            try? wantSig.write(to: sigFile, atomically: true, encoding: .utf8)
            bakeProgress[assetId] = nil
            return output
        } catch {
            bakeProgress[assetId] = nil
            Log.proxy.error("export stab bake failed id=\(assetId.prefix(8)): \(Log.detail(error))")
            return nil
        }
    }

    /// Re-queue bakes for any enabled vidstab clip whose bake is missing or stale.
    func reconcileVidstabClips() {
        guard stabilizedDir != nil else { return }
        var seen = Set<String>()
        for track in editor.timeline.tracks {
            for clip in track.clips where clip.mediaType == .video {
                guard clip.stabilization?.enabled == true,
                      clip.stabilization?.engine == .vidstab,
                      seen.insert(clip.mediaRef).inserted,
                      let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                let smoothness = clip.stabilization?.smoothness ?? 0.5
                enqueueBake(assetId: clip.mediaRef, url: url, smoothness: smoothness)
            }
        }
    }

    // MARK: - Subject tracking

    func hasSubjectTrack(assetId: String) -> Bool {
        guard let base = baseDir, let url = editor.mediaAssetsById[assetId]?.url else { return false }
        return SubjectSidecarStore.read(
            assetId: assetId, baseDir: base, sourceSig: ProxySignature.of(url) ?? "") != nil
    }

    func enqueueSubjectTrack(assetId: String, url: URL) {
        guard baseDir != nil else { return }
        if hasSubjectTrack(assetId: assetId) { return }
        if runningSubject == assetId || pendingSubject.contains(where: { $0.assetId == assetId }) { return }
        pendingSubject.append((assetId, url))
        if subjectJob == nil { startSubjectDraining() }
    }

    private func startSubjectDraining() {
        subjectJob = Task { [weak self] in
            while let next = self?.dequeueSubject() {
                self?.runningSubject = next.assetId
                await self?.runSubjectTrack(assetId: next.assetId, url: next.url)
                self?.runningSubject = nil
            }
            self?.subjectJob = nil
        }
    }

    private func dequeueSubject() -> (assetId: String, url: URL)? {
        guard !pendingSubject.isEmpty else { return nil }
        return pendingSubject.removeFirst()
    }

    private func runSubjectTrack(assetId: String, url: URL) async {
        guard let base = baseDir, (try? await Self.gate.wait()) != nil else { return }
        defer { Task { await Self.gate.signal() } }
        progressByAsset[assetId] = 0
        let proxy = editor.mediaManifest.useProxies ? editor.mediaResolver.proxyURL(for: assetId) : nil
        let inputURL = proxy ?? url
        do {
            let (fps, frames) = try await SubjectTracker.track(input: inputURL) { p in
                Task { @MainActor [weak self] in self?.progressByAsset[assetId] = p }
            }
            let sidecar = SubjectSidecar(sourceSig: ProxySignature.of(url) ?? "", fps: fps, frames: frames)
            try SubjectSidecarStore.write(sidecar, assetId: assetId, baseDir: base)
            correctionCache.removeAll()
            progressByAsset[assetId] = 1
            editor.onPersistentStateChanged?()
            editor.videoEngine?.refreshVisuals()
        } catch is CancellationError {
            progressByAsset[assetId] = nil
        } catch {
            Log.proxy.error("subject tracking failed id=\(assetId.prefix(8)): \(Log.detail(error))")
            progressByAsset[assetId] = nil
        }
    }

    /// Re-queue subject tracking for any enabled subject-engine clip whose sidecar is missing.
    func reconcileSubjectClips() {
        guard baseDir != nil else { return }
        var seen = Set<String>()
        for track in editor.timeline.tracks {
            for clip in track.clips where clip.mediaType == .video {
                guard clip.stabilization?.enabled == true,
                      clip.stabilization?.engine == .subject,
                      seen.insert(clip.mediaRef).inserted,
                      !hasSubjectTrack(assetId: clip.mediaRef),
                      let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                enqueueSubjectTrack(assetId: clip.mediaRef, url: url)
            }
        }
    }

    func hasAnalysis(assetId: String) -> Bool {
        guard let base = baseDir, let url = editor.mediaAssetsById[assetId]?.url else { return false }
        return StabilizationSidecar.read(
            assetId: assetId, baseDir: base, requiringSig: ProxySignature.of(url)) != nil
    }

    /// Re-queue analysis for any stabilization-enabled clip whose sidecar is missing or stale —
    /// e.g. after reopening a project, importing a bundle, or bumping the analyzer version.
    /// Idempotent: `analyze` de-dupes clips that already have a current sidecar.
    func reconcileEnabledClips() {
        guard baseDir != nil else { return }
        var seen = Set<String>()
        for track in editor.timeline.tracks {
            for clip in track.clips where clip.mediaType == .video {
                // vidstab and subject clips don't use the Vision-global analysis queue.
                guard clip.stabilization?.enabled == true,
                      clip.stabilization?.engine.isNative == true,
                      clip.stabilization?.engine != .subject,
                      seen.insert(clip.mediaRef).inserted,
                      !hasAnalysis(assetId: clip.mediaRef),
                      let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                analyze(assetId: clip.mediaRef, url: url)
            }
        }
    }

    /// Queue an asset for analysis (serial). De-dupes already-analyzed, in-flight, or queued assets.
    func analyze(assetId: String, url: URL) {
        guard baseDir != nil else { return }
        if hasAnalysis(assetId: assetId) { return }
        if running == assetId || pending.contains(where: { $0.assetId == assetId }) { return }
        pending.append((assetId, url))
        total += 1
        isAnalyzing = true
        if job == nil { startDraining() }
    }

    func cancel() {
        job?.cancel(); job = nil
        pending.removeAll()
        running = nil
        isAnalyzing = false
        completed = 0; total = 0
    }

    private func startDraining() {
        job = Task { [weak self] in
            while let next = self?.dequeue() {
                self?.running = next.assetId
                await self?.run(assetId: next.assetId, url: next.url)
                self?.running = nil
                self?.completed += 1
            }
            self?.finishDraining()
        }
    }

    private func dequeue() -> (assetId: String, url: URL)? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    private func finishDraining() {
        job = nil
        isAnalyzing = false
        completed = 0; total = 0
    }

    private func run(assetId: String, url: URL) async {
        guard let base = baseDir, (try? await Self.gate.wait()) != nil else { return }
        defer { Task { await Self.gate.signal() } }
        progressByAsset[assetId] = 0
        do {
            // Analyze the SOURCE (downscaled internally): low-res proxy registration is too noisy
            // and the noise, applied as a correction, makes footage shakier instead of steadier.
            let (fps, frames) = try await StabilizationAnalyzer.analyze(url: url) { p in
                Task { @MainActor [weak self] in self?.progressByAsset[assetId] = p }
            }
            let payload = StabSidecar(sourceSig: ProxySignature.of(url) ?? "", fps: fps, frames: frames)
            try StabilizationSidecar.write(payload, assetId: assetId, baseDir: base)
            correctionCache.removeAll()
            progressByAsset[assetId] = 1
            editor.onPersistentStateChanged?()
            editor.videoEngine?.refreshVisuals()
        } catch is CancellationError {
            progressByAsset[assetId] = nil
        } catch {
            Log.proxy.error("stabilization analyze failed id=\(assetId.prefix(8)): \(Log.detail(error))")
            progressByAsset[assetId] = nil
        }
    }

    /// Per-frame corrections for a clip, from the cached sidecar + clip params.
    /// Returns nil when no analysis/tracking exists or stabilization is disabled.
    func corrections(for clip: Clip, assetURL: URL) -> PathSmoother.Result? {
        guard let stab = clip.stabilization, stab.enabled, let base = baseDir else { return nil }
        let key = "\(clip.mediaRef)|\(stab.method.rawValue)|\(stab.engine.rawValue)|\(stab.smoothness)|\(stab.cropToFit)|\(clip.trimStartFrame)|\(clip.trimEndFrame)|\(clip.durationFrames)"
        if let hit = correctionCache[key] { return hit }

        // Subject engine: read the subject sidecar and run position-only L1 smoothing.
        if stab.engine == .subject {
            guard let sourceSig = ProxySignature.of(assetURL),
                  let sidecar = SubjectSidecarStore.read(
                      assetId: clip.mediaRef, baseDir: base, sourceSig: sourceSig)
            else { return nil }
            let start = clip.trimStartFrame
            let end = min(sidecar.frames.count, start + clip.sourceFramesConsumed)
            guard end > start else { return nil }
            let result = PathSmoother.corrections(
                raw: sidecar.frames, window: start..<end,
                method: .position, engine: .l1,
                smoothness: stab.smoothness, cropToFit: stab.cropToFit)
            correctionCache[key] = result
            return result
        }

        guard let sidecar = StabilizationSidecar.read(
            assetId: clip.mediaRef, baseDir: base,
            requiringSig: ProxySignature.of(assetURL)) else { return nil }
        let start = clip.trimStartFrame
        let end = min(sidecar.frames.count, start + clip.sourceFramesConsumed)
        let result = PathSmoother.corrections(
            raw: sidecar.frames, window: start..<max(start, end),
            method: stab.method, engine: stab.engine, smoothness: stab.smoothness, cropToFit: stab.cropToFit)
        correctionCache[key] = result
        return result
    }

    func invalidateCache() { correctionCache.removeAll() }

    /// Resolve per-clip stabilization corrections for the compositor, given the sizes/transforms
    /// produced by a composition build. Shared by preview (VideoEngine) and export (ExportService).
    func resolveStabByClip(
        clipNaturalSizes: [String: CGSize],
        clipTransforms: [String: CGAffineTransform]
    ) -> [String: StabResolved] {
        var stabByClip: [String: StabResolved] = [:]
        for track in editor.timeline.tracks {
            for clip in track.clips where clip.mediaType == .video {
                guard let stab = clip.stabilization, stab.enabled, stab.engine.isNative, clip.speed == 1.0,
                      let srcURL = editor.mediaResolver.resolveURL(for: clip.mediaRef),
                      let result = corrections(for: clip, assetURL: srcURL)
                else { continue }
                let zoom = CGFloat(result.cropZoom)
                if stab.method == .perspective {
                    stabByClip[clip.id] = StabResolved(affines: [], perspective: result.corrections, zoom: zoom)
                } else {
                    let displaySize = clipNaturalSizes[clip.id] ?? .zero
                    guard displaySize.width > 0, displaySize.height > 0 else { continue }
                    // Corrections are in raw (pre-rotation) frame space; if preferredTransform
                    // rotates ±90°, the raw frame has width/height swapped vs the display size.
                    let pt = clipTransforms[clip.id] ?? .identity
                    let rawSize = abs(pt.a) < abs(pt.b)
                        ? CGSize(width: displaySize.height, height: displaySize.width)
                        : displaySize
                    let affines = result.corrections.map {
                        CompositionBuilder.normalizedHomographyToAffine($0, natSize: rawSize, zoom: zoom)
                    }
                    stabByClip[clip.id] = StabResolved(affines: affines, perspective: nil, zoom: 1)
                }
            }
        }
        return stabByClip
    }
}
