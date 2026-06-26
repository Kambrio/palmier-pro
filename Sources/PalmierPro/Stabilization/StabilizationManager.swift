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

    init(editor: EditorViewModel) { self.editor = editor }

    private var baseDir: URL? { editor.projectURL }

    func hasAnalysis(assetId: String) -> Bool {
        guard let base = baseDir, let url = editor.mediaAssetsById[assetId]?.url else { return false }
        return StabilizationSidecar.read(
            assetId: assetId, baseDir: base, requiringSig: ProxySignature.of(url)) != nil
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
            // Analyze the cheap proxy when available; homographies are resolution-independent.
            // Sidecar is keyed by the SOURCE signature so corrections() lookup always matches.
            let analysisURL = editor.mediaResolver.proxyURL(for: assetId) ?? url
            let (fps, frames) = try await StabilizationAnalyzer.analyze(url: analysisURL) { p in
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
    /// Returns nil when no analysis exists or stabilization is disabled.
    func corrections(for clip: Clip, assetURL: URL) -> PathSmoother.Result? {
        guard let stab = clip.stabilization, stab.enabled, let base = baseDir else { return nil }
        let key = "\(clip.mediaRef)|\(stab.method.rawValue)|\(stab.smoothness)|\(stab.cropToFit)|\(clip.trimStartFrame)|\(clip.trimEndFrame)|\(clip.durationFrames)"
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

    /// Resolve per-clip stabilization corrections for the compositor, given the sizes/transforms
    /// produced by a composition build. Shared by preview (VideoEngine) and export (ExportService).
    func resolveStabByClip(
        clipNaturalSizes: [String: CGSize],
        clipTransforms: [String: CGAffineTransform]
    ) -> [String: StabResolved] {
        var stabByClip: [String: StabResolved] = [:]
        for track in editor.timeline.tracks {
            for clip in track.clips where clip.mediaType == .video {
                guard let stab = clip.stabilization, stab.enabled, clip.speed == 1.0,
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
