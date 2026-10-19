import Foundation

/// Per-project indexing queue and search
@MainActor
@Observable
final class SearchIndexCoordinator {
    struct PreflightRequest: Sendable {
        let url: URL
        let type: ClipType
        let hasAudio: Bool
        let spec: VisualEmbedder.Spec
    }

    struct PreflightResult: Equatable, Sendable {
        let needsVisual: Bool
        let needsTranscript: Bool

        var needsIndex: Bool { needsVisual || needsTranscript }
    }

    private struct AssetSnapshot: Equatable, Sendable {
        let id: String
        let url: URL
        let type: ClipType
        let duration: Double
        let hasAudio: Bool
        let isGenerating: Bool
    }

    private struct IndexWork: Sendable {
        let asset: AssetSnapshot
        /// Nil for gemma-only work (any type), enqueued when no SigLIP model is available.
        let spec: VisualEmbedder.Spec?
    }

    private(set) var batchTotal = 0
    private(set) var batchCompleted = 0
    private(set) var currentAssetFraction: Double = 0

    var indexingActive: Bool { batchCompleted < batchTotal }
    var indexingProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min(1, (Double(batchCompleted) + min(max(currentAssetFraction, 0), 1)) / Double(batchTotal))
    }

    var assetsProvider: () -> [MediaAsset] = { [] }
    /// On-disk source URL per asset id, so gemma keys survive proxy resolution.
    var manifestSourceLookup: @MainActor (String) -> URL? = { _ in nil }

    /// Source-map snapshot for gemma store readers outside the coordinator (tools, footage groups).
    func gemmaSourceMap() -> [String: URL?] {
        var map: [String: URL?] = [:]
        for asset in assetsProvider() { map[asset.id] = manifestSourceLookup(asset.id) }
        return map
    }

    private var queue: [IndexWork] = []
    private var scheduledIds: Set<String> = []
    private var isCancelling = false
    private var failedIds: Set<String> = []
    private var worker: Task<Void, Never>?
    /// Bumped whenever `worker` is replaced or cancelled, so a stale worker's
    /// exit path can't clobber the reference to a newer one.
    private var workerGeneration = 0
    private var loadedIndexes: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]

    private static let registry = NSHashTable<SearchIndexCoordinator>.weakObjects()
    private static var live: [SearchIndexCoordinator] { registry.allObjects }

    init() {
        Self.registry.add(self)
    }

    // MARK: - App-level fan-out

    static func sweepAll() { for c in live { c.sweep() } }
    static func cancelAll() async { for c in live { await c.cancelIndexing() } }
    static func resetAll() async {
        for c in live {
            await c.cancelIndexing()
            c.loadedIndexes.removeAll()
            c.failedIds.removeAll()
        }
    }

    static func clearIndexGlobally() async {
        await resetAll()
        EmbeddingStore.clearAll()
        sweepAll()
    }

    // MARK: - Triggers

    func projectOpened() {
        Log.search.notice(
            "index project opened enabled=\(VisualModelLoader.shared.enabled)",
            telemetry: "Search index project opened",
            data: ["enabled": VisualModelLoader.shared.enabled]
        )
        Task {
            await VisualModelLoader.shared.prepare()
            await GemmaModelManager.shared.prepare()
            sweep()
        }
    }

    /// Enqueue all current assets that need (re)indexing.
    /// Failed assets get a fresh chance; failedIds only dedupes within a batch.
    func sweep() {
        guard VisualModelLoader.shared.enabled || GemmaModelManager.shared.enabled else { return }
        failedIds.removeAll()
        let assets = assetsProvider()
        Log.search.notice(
            "index sweep assets=\(assets.count) queuedBefore=\(queue.count)",
            telemetry: "Search index sweep",
            data: [
                "assets": assets.count,
                "ready": VisualModelLoader.shared.isReady,
                "queuedBefore": queue.count
            ]
        )
        for asset in assets {
            schedule(asset)
        }
    }

    func schedule(_ asset: MediaAsset) {
        guard !isCancelling, !asset.isGenerating else { return }
        guard !scheduledIds.contains(asset.id), !failedIds.contains(asset.id) else { return }
        let snapshot = Self.snapshot(asset)
        if VisualModelLoader.shared.enabled, let model = VisualModelLoader.shared.embedder {
            queue.append(IndexWork(asset: snapshot, spec: model.spec))
        } else if GemmaModelManager.shared.enabled, GemmaModelManager.shared.isReady {
            // Gemma-only indexing: SigLIP absent or still loading, but gemma can take the asset.
            queue.append(IndexWork(asset: snapshot, spec: nil))
        } else {
            return
        }
        scheduledIds.insert(snapshot.id)
        batchTotal += 1
        ensureWorker()
    }

    nonisolated static func preflight(_ request: PreflightRequest) -> PreflightResult {
        let needsVisual = (request.type == .video || request.type == .image)
            && VisualIndexer.needsIndex(url: request.url, spec: request.spec)
        let needsTranscript = (request.type == .audio || (request.type == .video && request.hasAudio))
            && !TranscriptCache.hasCachedOnDisk(for: request.url)
        return PreflightResult(needsVisual: needsVisual, needsTranscript: needsTranscript)
    }

    private func needsTranscript(_ asset: MediaAsset) -> Bool {
        (asset.type == .audio || (asset.type == .video && asset.hasAudio))
            && !TranscriptCache.hasCachedOnDisk(for: asset.url, engineTag: TranscriptCache.currentEngineTag())
    }

    /// Stops the worker and waits for the in-flight asset to actually stop.
    private func cancelIndexing() async {
        isCancelling = true
        defer { isCancelling = false }
        let current = worker
        workerGeneration += 1
        worker = nil
        queue.removeAll()
        scheduledIds.removeAll()
        resetBatch()
        current?.cancel()
        await current?.value
        resetBatch()
    }

    private static func snapshot(_ asset: MediaAsset) -> AssetSnapshot {
        AssetSnapshot(
            id: asset.id,
            url: asset.url,
            type: asset.type,
            duration: asset.duration,
            hasAudio: asset.hasAudio,
            isGenerating: asset.isGenerating
        )
    }

    // MARK: - Worker

    private func ensureWorker() {
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        Log.search.notice(
            "index worker start generation=\(generation) depth=\(queue.count)",
            telemetry: "Search index worker started",
            data: ["generation": generation, "queueDepth": queue.count, "batchTotal": batchTotal]
        )
        worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, let work = self.dequeue() {
                self.currentAssetFraction = 0
                await self.process(work)
            }
            if let self, self.workerGeneration == generation {
                self.worker = nil
            }
        }
    }

    private func dequeue() -> IndexWork? {
        guard !queue.isEmpty else {
            resetBatch()
            return nil
        }
        return queue.removeFirst()
    }

    private func process(_ work: IndexWork) async {
        var retry: MediaAsset?
        defer {
            scheduledIds.remove(work.asset.id)
            batchCompleted += 1
            if let retry { schedule(retry) }
        }

        // Gemma-only work: no SigLIP preflight; the gemma pass checks its own staleness.
        guard let spec = work.spec else {
            guard isCurrent(work) else {
                retry = assetsProvider().first { $0.id == work.asset.id }
                return
            }
            while ExportQueue.shared.isExportActive, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            guard isCurrent(work) else {
                retry = assetsProvider().first { $0.id == work.asset.id }
                return
            }
            await indexOne(work.asset, model: nil, transcribe: false)
            return
        }

        let request = PreflightRequest(
            url: work.asset.url,
            type: work.asset.type,
            hasAudio: work.asset.hasAudio,
            spec: spec
        )
        let task = Task.detached(priority: .utility) { Self.preflight(request) }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled else { return }

        guard isCurrent(work) else {
            retry = assetsProvider().first { $0.id == work.asset.id }
            return
        }
        // A current SigLIP index must not gate the gemma pass: indexOne re-checks staleness internally.
        let gemmaEligible = GemmaModelManager.shared.enabled
            && GemmaModelManager.shared.isReady
            && (work.asset.type == .video || work.asset.type == .audio)
        guard result.needsIndex || gemmaEligible else { return }

        while ExportQueue.shared.isExportActive, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
        }
        guard !Task.isCancelled else { return }
        guard isCurrent(work), let model = VisualModelLoader.shared.embedder else {
            retry = assetsProvider().first { $0.id == work.asset.id }
            return
        }
        await indexOne(work.asset, model: model, transcribe: result.needsTranscript)
    }

    private func isCurrent(_ work: IndexWork) -> Bool {
        if work.spec == nil {
            guard GemmaModelManager.shared.enabled, GemmaModelManager.shared.isReady,
                  let asset = assetsProvider().first(where: { $0.id == work.asset.id }) else { return false }
            return Self.snapshot(asset) == work.asset
        }
        guard VisualModelLoader.shared.enabled,
              VisualModelLoader.shared.embedder?.spec == work.spec,
              let asset = assetsProvider().first(where: { $0.id == work.asset.id }) else { return false }
        return Self.snapshot(asset) == work.asset
    }

    private func resetBatch() {
        batchTotal = 0
        batchCompleted = 0
        currentAssetFraction = 0
    }

    private func indexOne(
        _ asset: AssetSnapshot,
        model: VisualEmbedder?,
        transcribe: Bool
    ) async {
        let visualShare = transcribe ? 0.5 : 1.0
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in self?.currentAssetFraction = fraction * visualShare }
        }
        let url = asset.url
        let isVideo = asset.type == .video
        let engineTag = TranscriptCache.currentEngineTag()
        let start = ContinuousClock.now
        do {
            async let transcriptDone: Void = {
                if transcribe {
                    try await ExportQueue.shared.waitWhileExportActive()
                    _ = try await TranscriptCache.shared.transcript(for: url, isVideo: isVideo, range: nil, engineTag: engineTag)
                }
            }()
            if let model {
                switch asset.type {
                case .image:
                    try await VisualIndexer.indexImage(url: url, model: model)
                case .video:
                    try await VisualIndexer.index(
                        url: url, duration: asset.duration, model: model, progress: onProgress
                    )
                default:
                    break
                }
            }
            try await runGemmaPass(asset, url: url)
            loadedIndexes[asset.id] = nil
            let visualSeconds = start.duration(to: .now).seconds
            currentAssetFraction = visualShare
            try await transcriptDone
            let totalSeconds = start.duration(to: .now).seconds
            Log.search.debug("""
                indexed \(asset.id.prefix(8)) visual=\(String(format: "%.1f", visualSeconds))s \
                total=\(String(format: "%.1f", totalSeconds))s transcribed=\(transcribe)
                """)
        } catch is CancellationError {
            Log.search.debug("index cancelled asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)")
        } catch {
            failedIds.insert(asset.id)
            Log.search.warning("index failed asset=\(asset.id.prefix(8)): \(error.localizedDescription)")
        }
    }

    /// Gemma indexing beside the SigLIP pass; keying and staleness checks stat files, so all of it runs off-actor.
    private func runGemmaPass(_ asset: AssetSnapshot, url: URL) async throws {
        guard GemmaModelManager.shared.enabled, GemmaModelManager.shared.isReady,
              let gemma = GemmaModelManager.shared.embedder,
              asset.type == .video || asset.type == .audio else { return }
        let sourceURL = manifestSourceLookup(asset.id)
        let indexURL = url
        let duration = asset.duration
        let type = asset.type
        let hasAudio = asset.hasAudio
        let assetID = asset.id
        let engineTag = TranscriptCache.currentEngineTag()
        let task = Task.detached(priority: .utility) {
            guard let key = GemmaIndexer.key(assetID: assetID, url: indexURL, sources: [assetID: sourceURL]) else { return }
            switch type {
            case .video:
                // A cancelled audio pass leaves a current record with audio: [] — re-run for that alone.
                guard GemmaIndexer.needsIndex(key: key)
                    || GemmaIndexer.needsAudioPass(key: key, hasAudio: hasAudio) else { return }
                try await GemmaIndexer.indexVideo(indexURL: indexURL, key: key, duration: duration, embedder: gemma)
                if hasAudio {
                    try await GemmaIndexer.indexAudio(url: indexURL, key: key, embedder: gemma)
                }
                await Self.embedTranscript(key: key, url: indexURL, isVideo: true, engineTag: engineTag, embedder: gemma)
            case .audio:
                guard !ClipEmbedStore.isCurrent(
                    key: key, model: GemmaIndexer.modelName, modelVersion: GemmaIndexer.modelVersion
                ) else { return }
                try await GemmaIndexer.indexAudio(url: indexURL, key: key, embedder: gemma)
                await Self.embedTranscript(key: key, url: indexURL, isVideo: false, engineTag: engineTag, embedder: gemma)
            default:
                break
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// A transcript miss must never fail the visual pass, so every failure here is logged and swallowed.
    private nonisolated static func embedTranscript(
        key: String, url: URL, isVideo: Bool, engineTag: String, embedder: any GemmaEmbedding
    ) async {
        do {
            let result = try await TranscriptCache.shared.transcript(
                for: url, isVideo: isVideo, range: nil, engineTag: engineTag)
            guard GemmaIndexer.worthEmbedding(result.text) else { return }
            if try await GemmaIndexer.embedTranscript(key: key, text: result.text, embedder: embedder) {
                Log.search.debug("transcript fused key=\(key.prefix(12)) chars=\(result.text.count)")
            }
        } catch {
            Log.search.debug("transcript fuse skipped key=\(key.prefix(12)): \(error.localizedDescription)")
        }
    }

    // MARK: - Query

    func search(query: String, limit: Int = 20, within ids: Set<String>? = nil) async -> [VisualSearch.Hit] {
        // Gemma-only mode: with SigLIP absent the gemma half still runs; both absent means no search.
        let siglipModel = VisualModelLoader.shared.isReady ? VisualModelLoader.shared.embedder : nil
        let gemmaReady = GemmaModelManager.shared.enabled && GemmaModelManager.shared.isReady
        guard siglipModel != nil || gemmaReady else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Snapshot on main; stat/SHA256/file reads, encode, and ranking happen off-actor.
        let candidates = assetsProvider()
            .filter { ($0.type == .video || $0.type == .image) && (ids?.contains($0.id) ?? true) }
            .map { ($0.id, $0.url) }
        let cached = loadedIndexes
        let minScore = SearchIndexConfig.visualMatchCosineFloor

        let (siglipHits, loaded) = await Task.detached(priority: .userInitiated) {
            () -> ([VisualSearch.Hit], [String: (key: String, index: EmbeddingStore.AssetIndex)]) in
            guard let model = siglipModel else { return ([VisualSearch.Hit](), [:]) }
            var indexes: [(String, EmbeddingStore.AssetIndex)] = []
            var loaded: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]
            for (assetID, url) in candidates {
                guard let key = EmbeddingStore.key(for: url) else { continue }
                if let hit = cached[assetID], hit.key == key {
                    indexes.append((assetID, hit.index))
                } else if let index = try? EmbeddingStore.load(key: key) {
                    loaded[assetID] = (key, index)
                    indexes.append((assetID, index))
                }
            }
            guard !indexes.isEmpty, let vector = try? model.encode(text: trimmed) else {
                return ([VisualSearch.Hit](), loaded)
            }
            return (VisualSearch.search(query: vector, indexes: indexes, limit: limit, minScore: minScore), loaded)
        }.value

        loadedIndexes.merge(loaded) { _, new in new }

        // Gemma re-ranking fused with the SigLIP hits; loads gemma stores directly —
        // loadedIndexes caches SigLIP stores under the same keys.
        var hits = siglipHits
        if GemmaModelManager.shared.enabled, GemmaModelManager.shared.isReady,
           let gemma = GemmaModelManager.shared.embedder {
            let gemmaSources = candidates.reduce(into: [String: URL?]()) { map, entry in
                map[entry.0] = manifestSourceLookup(entry.0)
            }
            let gemmaHits = await Task.detached(priority: .userInitiated) { () -> [GemmaSearch.Hit] in
                var frameIndexes: [(assetID: String, index: EmbeddingStore.AssetIndex)] = []
                var clipRecords: [(assetID: String, record: ClipEmbedStore.Record)] = []
                for (assetID, url) in candidates {
                    let (frameIndex, record) = GemmaIndexer.stores(assetID: assetID, url: url, sources: gemmaSources)
                    if let frameIndex { frameIndexes.append((assetID: assetID, index: frameIndex)) }
                    if let record { clipRecords.append((assetID: assetID, record: record)) }
                }
                guard let vector = try? await gemma.embedText(trimmed, task: .searchQuery) else { return [] }
                return GemmaSearch.search(query: vector, frameIndexes: frameIndexes,
                                          clipRecords: clipRecords, limit: limit)
            }.value
            hits = GemmaSearch.fuse(hits, gemmaHits, limit: limit)
        }
        return hits
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
