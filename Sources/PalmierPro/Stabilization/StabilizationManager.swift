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
    /// In-memory cache of correction results keyed by clip + params.
    @ObservationIgnored private var correctionCache: [String: PathSmoother.Result] = [:]

    init(editor: EditorViewModel) { self.editor = editor }

    private var baseDir: URL? { editor.projectURL }

    func hasAnalysis(assetId: String) -> Bool {
        guard let base = baseDir, let url = editor.mediaAssetsById[assetId]?.url else { return false }
        return StabilizationSidecar.read(
            assetId: assetId, baseDir: base, requiringSig: ProxySignature.of(url)) != nil
    }

    /// Analyze the asset if not already cached; no-op if running or unsaved.
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
            let payload = StabSidecar(sourceSig: ProxySignature.of(url) ?? "", fps: fps, frames: frames)
            try StabilizationSidecar.write(payload, assetId: assetId, baseDir: base)
            correctionCache.removeAll()
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

    /// Per-frame corrections for a clip, from the cached sidecar + clip params.
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
