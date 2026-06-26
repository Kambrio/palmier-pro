import AVFoundation
import Foundation
import os

@MainActor
@Observable
final class ProxyManager {
    private unowned let editor: EditorViewModel
    // Serial: concurrent 6K→ProRes transcodes cause memory pressure that corrupts finalize.
    private static let gate = AsyncSemaphore(value: 1)
    private(set) var isGenerating = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var startedAt: Date?
    private(set) var totalDuration: Double = 0      // media-seconds across all targets
    private(set) var processedDuration: Double = 0  // media-seconds finished so far
    private(set) var bytesThisRun: Int64 = 0        // proxy bytes written so far
    private var job: Task<Void, Never>?

    /// Wall-clock seconds left, extrapolated from media-seconds processed so far.
    func eta(asOf now: Date = Date()) -> TimeInterval? {
        guard isGenerating, let startedAt, processedDuration > 0,
              totalDuration > processedDuration else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        return max(0, elapsed / processedDuration * (totalDuration - processedDuration))
    }

    /// Projected total size of this run's proxies, from bytes-per-media-second so far.
    var estimatedRunBytes: Int64? {
        guard processedDuration > 0, bytesThisRun > 0, totalDuration > 0 else { return nil }
        return Int64(Double(bytesThisRun) / processedDuration * totalDuration)
    }

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

    /// Asset ids that have a proxy on disk but aren't used by any timeline clip.
    func unusedProxyAssetIds() -> [String] {
        let used = Set(editor.timeline.tracks.flatMap(\.clips).map(\.mediaRef))
        return editor.mediaManifest.entries.compactMap { entry in
            (entry.proxyPath != nil && !used.contains(entry.id)) ? entry.id : nil
        }
    }

    /// Remove proxies for media not on the timeline, freeing space without losing
    /// proxies for clips still in use.
    func deleteUnusedProxies() {
        guard let base = editor.projectURL else { return }
        let unused = Set(unusedProxyAssetIds())
        guard !unused.isEmpty else { return }
        for i in editor.mediaManifest.entries.indices where unused.contains(editor.mediaManifest.entries[i].id) {
            if let rel = editor.mediaManifest.entries[i].proxyPath {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(rel))
            }
            editor.mediaManifest.entries[i].proxyPath = nil
            editor.mediaManifest.entries[i].proxySourceSig = nil
        }
        editor.proxyBackedMediaRefs.subtract(unused)
        for asset in editor.mediaAssets where unused.contains(asset.id) { asset.proxyState = .none }
        editor.onPersistentStateChanged?()
        if editor.mediaManifest.useProxies { editor.videoEngine?.rebuild() }
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
        editor.proxyBackedMediaRefs.removeAll()
        editor.onPersistentStateChanged?()
        if editor.mediaManifest.useProxies { editor.videoEngine?.rebuild() }
    }

    /// Checks each manifest entry with a proxy path; removes entries whose file exists but
    /// is not an openable finalized movie. Capped to 4 concurrent openability checks.
    func validateAndPruneProxies() async {
        guard let base = editor.projectURL else { return }
        var changed = false
        // Collect indices with a non-nil proxyPath up front (manifest is mutated below).
        let indices = editor.mediaManifest.entries.indices.filter { editor.mediaManifest.entries[$0].proxyPath != nil }
        // Process in batches of 4 to avoid opening hundreds of files concurrently.
        let batchSize = 4
        var i = indices.startIndex
        while i < indices.endIndex {
            let batchEnd = indices.index(i, offsetBy: batchSize, limitedBy: indices.endIndex) ?? indices.endIndex
            let batch = Array(indices[i..<batchEnd])
            // Collect the (manifestIndex, url) pairs for this batch.
            var toCheck: [(Int, URL)] = []
            for idx in batch {
                guard let rel = editor.mediaManifest.entries[idx].proxyPath else { continue }
                let url = base.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                toCheck.append((idx, url))
            }
            // Check openability concurrently (suspends without blocking main actor).
            var corruptIndices: [Int] = []
            await withTaskGroup(of: (Int, Bool).self) { group in
                for (idx, url) in toCheck {
                    group.addTask { (idx, await ProxyService.isOpenableVideo(url)) }
                }
                for await (idx, openable) in group where !openable {
                    corruptIndices.append(idx)
                }
            }
            // Prune corrupt entries on the main actor (we're already @MainActor).
            for idx in corruptIndices {
                guard let rel = editor.mediaManifest.entries[idx].proxyPath else { continue }
                let url = base.appendingPathComponent(rel)
                let assetId = editor.mediaManifest.entries[idx].id
                Log.proxy.notice("pruning corrupt proxy id=\(assetId.prefix(8)) path=\(rel)")
                try? FileManager.default.removeItem(at: url)
                editor.mediaManifest.entries[idx].proxyPath = nil
                editor.mediaManifest.entries[idx].proxySourceSig = nil
                editor.proxyBackedMediaRefs.remove(assetId)
                if let asset = editor.mediaAssets.first(where: { $0.id == assetId }) {
                    asset.proxyState = .none
                }
                changed = true
            }
            i = batchEnd
        }
        if changed {
            editor.onPersistentStateChanged?()
            if editor.mediaManifest.useProxies { editor.videoEngine?.rebuild() }
        }
    }

    /// Background-generate proxies for all assets that need them. No-op if running or unsaved.
    func createProxies() {
        guard !isGenerating, editor.projectURL != nil else { return }
        guard let dir = proxiesDir else { return }
        let resolution = editor.mediaManifest.proxyResolution

        isGenerating = true; completed = 0; total = 0
        processedDuration = 0; bytesThisRun = 0; startedAt = nil
        job = Task { [weak self] in
            guard let self else { return }
            // Prune corrupt proxies first so assetsNeedingProxies picks them up for regeneration.
            await self.validateAndPruneProxies()
            let targets = self.assetsNeedingProxies()
            guard !targets.isEmpty else {
                self.isGenerating = false
                return
            }
            self.total = targets.count
            self.startedAt = Date()
            self.totalDuration = targets.reduce(0) { $0 + max(0, $1.duration) }
            Log.proxy.notice("createProxies begin total=\(targets.count) res=\(resolution.label) dir=\(dir.path)")
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
        Log.proxy.notice("proxy start id=\(asset.id.prefix(8)) src=\(asset.url.lastPathComponent)")
        do {
            var lastError: Error?
            for attempt in 0..<2 {
                do {
                    // Throttle to integer-percent changes; otherwise every decoded frame hops the main actor.
                    let lastPct = OSAllocatedUnfairLock(initialState: -1)
                    try await ProxyService.transcode(source: asset.url, to: out, resolution: resolution) { p in
                        let pct = Int(p * 100)
                        let changed = lastPct.withLock { v -> Bool in if v == pct { return false }; v = pct; return true }
                        guard changed else { return }
                        Task { @MainActor in asset.proxyState = .generating(p) }
                    }
                    lastError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    Log.proxy.error("proxy attempt \(attempt + 1) failed id=\(asset.id.prefix(8)): \(Log.detail(error))")
                }
            }
            if let lastError { throw lastError }
            let sig = ProxySignature.of(asset.url)
            asset.proxyState = .ready
            Log.proxy.notice("proxy ok id=\(asset.id.prefix(8))")
            if let i = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[i].proxyPath = rel
                editor.mediaManifest.entries[i].proxySourceSig = sig
            }
            editor.proxyBackedMediaRefs.insert(asset.id)
            editor.onPersistentStateChanged?()
            bytesThisRun += (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            completed += 1; processedDuration += max(0, asset.duration)
            if editor.mediaManifest.useProxies { editor.videoEngine?.rebuild() }
        } catch is CancellationError {
            asset.proxyState = .none
            completed += 1
        } catch {
            Log.proxy.error("proxy failed id=\(asset.id.prefix(8)): \(Log.detail(error))")
            asset.proxyState = .failed(error.localizedDescription)
            completed += 1; processedDuration += max(0, asset.duration)
        }
    }
}
