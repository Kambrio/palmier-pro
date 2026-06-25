import Foundation

@MainActor
@Observable
final class ProxyManager {
    private unowned let editor: EditorViewModel
    private static let gate = AsyncSemaphore(value: 2)
    private(set) var isGenerating = false
    private(set) var completed = 0
    private(set) var total = 0
    private var job: Task<Void, Never>?

    init(editor: EditorViewModel) { self.editor = editor }

    private var proxiesDir: URL? {
        editor.projectURL?.appendingPathComponent("\(Project.mediaDirectoryName)/\(Project.proxiesDirname)", isDirectory: true)
    }

    /// Video assets lacking a current proxy (none, failed, or source changed).
    func assetsNeedingProxies() -> [MediaAsset] {
        editor.mediaAssets.filter { $0.type == .video && !hasCurrentProxy($0) }
    }

    private func hasCurrentProxy(_ asset: MediaAsset) -> Bool {
        guard let entry = editor.mediaManifest.entries.first(where: { $0.id == asset.id }),
              let rel = entry.proxyPath, let base = editor.projectURL else { return false }
        let url = base.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return entry.proxySourceSig == nil || entry.proxySourceSig == ProxySignature.of(asset.url)
    }

    /// Total bytes used by proxy files on disk.
    func proxyDiskUsage() -> Int64 {
        guard let dir = proxiesDir,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    /// Remove all proxy files and clear their manifest/asset references.
    func deleteProxies() {
        cancel()   // stop in-flight generation so it can't re-populate manifest paths
        if let dir = proxiesDir { try? FileManager.default.removeItem(at: dir) }
        for i in editor.mediaManifest.entries.indices {
            editor.mediaManifest.entries[i].proxyPath = nil
            editor.mediaManifest.entries[i].proxySourceSig = nil
        }
        for asset in editor.mediaAssets where asset.proxyState != .none { asset.proxyState = .none }
        if editor.mediaManifest.useProxies { editor.videoEngine?.rebuild() }
    }

    /// Background-generate proxies for all assets that need them. No-op if running or unsaved.
    func createProxies() {
        guard !isGenerating, editor.projectURL != nil else { return }
        let targets = assetsNeedingProxies()
        guard !targets.isEmpty, let dir = proxiesDir else { return }
        let resolution = editor.mediaManifest.proxyResolution

        isGenerating = true; completed = 0; total = targets.count
        job = Task { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await withTaskGroup(of: Void.self) { group in
                for asset in targets {
                    group.addTask { await self.generateOne(asset, into: dir, resolution: resolution) }
                }
                await group.waitForAll()
            }
            self.isGenerating = false
        }
    }

    func cancel() { job?.cancel(); job = nil; isGenerating = false }

    private func generateOne(_ asset: MediaAsset, into dir: URL, resolution: ProxyResolution) async {
        guard (try? await Self.gate.wait()) != nil else { return }
        defer { Task { await Self.gate.signal() } }
        asset.proxyState = .generating(0)
        let out = dir.appendingPathComponent("\(asset.id).mov")
        let rel = "\(Project.mediaDirectoryName)/\(Project.proxiesDirname)/\(asset.id).mov"
        do {
            try await ProxyService.transcode(source: asset.url, to: out, resolution: resolution) { p in
                Task { @MainActor in asset.proxyState = .generating(p) }
            }
            let sig = ProxySignature.of(asset.url)
            asset.proxyState = .ready
            if let i = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[i].proxyPath = rel
                editor.mediaManifest.entries[i].proxySourceSig = sig
            }
            completed += 1
            if editor.mediaManifest.useProxies { editor.videoEngine?.rebuild() }
        } catch {
            asset.proxyState = .failed(error.localizedDescription)
            completed += 1
        }
    }
}
