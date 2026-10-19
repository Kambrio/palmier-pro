import Foundation

/// Pure tool cores: store loads, ranking, and receipt shaping over explicit inputs.
/// No GemmaModelManager, no editor — the ToolExecutor wrappers below snapshot state
/// on the main actor and dispatch these from detached tasks.
enum GemmaToolCore {
    static func findMoments(
        query: String,
        embedder: any GemmaEmbedding,
        candidates: [(id: String, url: URL)],
        sources: [String: URL?],
        limit: Int,
        fps: Int
    ) async throws -> ToolResult {
        let stores = gemmaStores(for: candidates, sources: sources)
        guard !stores.frameIndexes.isEmpty || !stores.clipRecords.isEmpty else {
            return try receipt([
                "moments": [Any](),
                "note": "no gemma indexes yet — indexing still running",
            ])
        }
        let vector = try await embedder.embedText(query, task: .searchQuery)
        try Task.checkCancellation()
        let hits = GemmaSearch.search(
            query: vector, frameIndexes: stores.frameIndexes,
            clipRecords: stores.clipRecords, limit: limit)
        return try receipt(["moments": hits.map(momentEntry), "timelineFps": fps])
    }

    static func clusterFootage(
        candidates: [(id: String, url: URL)],
        totalVideoAssets: Int
    ) throws -> ToolResult {
        let items: [(id: String, vector: [Float])] = candidates.compactMap { candidate in
            guard let key = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: candidate.url),
                  let vector = ClipEmbedStore.load(key: key)?.clipVector else { return nil }
            return (id: candidate.id, vector: vector)
        }
        let coverage = ["assets": totalVideoAssets, "grouped": items.count]
        guard !items.isEmpty else {
            return try receipt([
                "groups": [Any](),
                "similarTakes": [[String]](),
                "coverage": coverage,
                "note": "no clip embeddings yet — indexing still running",
            ])
        }
        let k = max(2, Int((Double(items.count) / 2).squareRoot().rounded()))
        return try receipt([
            "groups": FootageGroups.groups(items: items, k: k)
                .map { ["memberIds": $0.memberIDs, "size": $0.memberIDs.count] },
            "similarTakes": FootageGroups.nearDuplicates(items: items),
            "coverage": coverage,
        ])
    }

    static func matchAudio(
        voiceID: String,
        voiceURL: URL,
        candidates: [(id: String, url: URL)],
        sources: [String: URL?],
        limit: Int,
        fps: Int
    ) throws -> ToolResult {
        guard let voiceKey = GemmaIndexer.indexKey(sourceURL: sources[voiceID] ?? nil, fallbackURL: voiceURL),
              let voiceRecord = ClipEmbedStore.load(key: voiceKey),
              let query = voiceRecord.audio.first?.vector else {
            return .error(
                "match_audio: no audio embeddings for asset \(voiceID) yet — indexing still running or the asset has no audio")
        }
        var searchable: [(assetID: String, record: ClipEmbedStore.Record)] = []
        for candidate in candidates where candidate.id != voiceID {
            guard let key = GemmaIndexer.indexKey(
                      sourceURL: sources[candidate.id] ?? nil, fallbackURL: candidate.url),
                  let record = ClipEmbedStore.load(key: key) else { continue }
            searchable.append((assetID: candidate.id, record: record))
        }
        let matches = GemmaSearch.audioMatches(voice: query, candidates: searchable, limit: limit)
        guard !matches.isEmpty else {
            return try receipt(["matches": [Any](), "note": "no similar audio moments found"])
        }
        return try receipt([
            "voiceAssetId": voiceID,
            "matches": matches.map {
                ["videoAssetId": $0.assetID, "start": $0.start, "end": $0.end, "score": Double($0.score)]
            },
            "timelineFps": fps,
        ])
    }

    static func momentEntry(_ hit: GemmaSearch.Hit) -> [String: Any] {
        var entry: [String: Any] = ["assetId": hit.assetID, "score": Double(hit.score)]
        switch hit.kind {
        case .frame(let time, let shotStart, let shotEnd):
            entry["kind"] = "frame"
            entry["time"] = time
            entry["start"] = shotStart
            entry["end"] = shotEnd
        case .clip:
            entry["kind"] = "clip"
        case .audio(let start, let end):
            entry["kind"] = "audio"
            entry["start"] = start
            entry["end"] = end
        }
        return entry
    }

    /// Frame and clip-record stores keyed exactly as the coordinator's indexing pass wrote them.
    static func gemmaStores(
        for candidates: [(id: String, url: URL)],
        sources: [String: URL?]
    ) -> (frameIndexes: [(assetID: String, index: EmbeddingStore.AssetIndex)],
          clipRecords: [(assetID: String, record: ClipEmbedStore.Record)]) {
        var frameIndexes: [(assetID: String, index: EmbeddingStore.AssetIndex)] = []
        var clipRecords: [(assetID: String, record: ClipEmbedStore.Record)] = []
        for candidate in candidates {
            guard let key = GemmaIndexer.indexKey(
                sourceURL: sources[candidate.id] ?? nil, fallbackURL: candidate.url) else { continue }
            if let index = try? EmbeddingStore.load(key: key),
               index.header.model == GemmaIndexer.modelName {
                frameIndexes.append((assetID: candidate.id, index: index))
            }
            if let record = ClipEmbedStore.load(key: key) {
                clipRecords.append((assetID: candidate.id, record: record))
            }
        }
        return (frameIndexes, clipRecords)
    }

    private static func receipt(_ payload: [String: Any]) throws -> ToolResult {
        try Task.checkCancellation()
        guard let json = ToolExecutor.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("failed to encode results")
        }
        return .ok(json)
    }
}

extension ToolExecutor {
    private static let findMomentsAllowedKeys: Set<String> = ["query", "limit"]
    private static let clusterFootageAllowedKeys: Set<String> = []
    private static let matchAudioAllowedKeys: Set<String> = ["voiceAssetId", "limit"]

    /// Embedder only when the EmbeddingGemma 2 capability is genuinely usable.
    private static var readyGemma: (any GemmaEmbedding)? {
        let manager = GemmaModelManager.shared
        guard manager.enabled, manager.isReady else { return nil }
        return manager.embedder
    }

    private static func gemmaCapabilityError(_ tool: String) -> ToolResult {
        .error("EmbeddingGemma 2 is not enabled. Enable it in Settings → Storage (EmbeddingGemma 2) to use \(tool).")
    }

    func findMoments(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.findMomentsAllowedKeys, path: "find_moments")
        let query = try args.requireString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError("find_moments: query is empty") }
        let limit = min(max(args.int("limit") ?? 20, 1), 100)
        guard let gemma = Self.readyGemma else { return Self.gemmaCapabilityError("find_moments") }

        let candidates = editor.mediaAssets
            .filter { $0.type == .video || $0.type == .audio }
            .map { (id: $0.id, url: $0.url) }
        let sources = Self.gemmaSourceMap(editor, ids: candidates.map(\.id))
        let fps = editor.timeline.fps
        let result = try await Task.detached(priority: .userInitiated) {
            try await GemmaToolCore.findMoments(
                query: query, embedder: gemma, candidates: candidates,
                sources: sources, limit: limit, fps: fps)
        }.value
        try Task.checkCancellation()
        return result
    }

    func clusterFootage(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.clusterFootageAllowedKeys, path: "cluster_footage")
        guard Self.readyGemma != nil else { return Self.gemmaCapabilityError("cluster_footage") }

        let videos = editor.mediaAssets.filter { $0.type == .video }
        let candidates = videos.map { (id: $0.id, url: $0.url) }
        let result = try await Task.detached(priority: .userInitiated) {
            try GemmaToolCore.clusterFootage(candidates: candidates, totalVideoAssets: videos.count)
        }.value
        try Task.checkCancellation()
        return result
    }

    func matchAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.matchAudioAllowedKeys, path: "match_audio")
        let voiceRef = try args.requireString("voiceAssetId")
        let voice = try asset(voiceRef, editor: editor, label: "Voice asset")
        let limit = min(max(args.int("limit") ?? 5, 1), 50)
        guard Self.readyGemma != nil else { return Self.gemmaCapabilityError("match_audio") }

        let candidates = editor.mediaAssets
            .filter { $0.type == .video || $0.type == .audio }
            .map { (id: $0.id, url: $0.url) }
        let sources = Self.gemmaSourceMap(editor, ids: candidates.map(\.id) + [voice.id])
        let fps = editor.timeline.fps
        let voiceID = voice.id
        let voiceURL = voice.url
        let result = try await Task.detached(priority: .userInitiated) {
            try GemmaToolCore.matchAudio(
                voiceID: voiceID, voiceURL: voiceURL, candidates: candidates,
                sources: sources, limit: limit, fps: fps)
        }.value
        try Task.checkCancellation()
        return result
    }

    /// On-disk source URL per asset id, so proxied assets key stores as the indexer did.
    private static func gemmaSourceMap(_ editor: EditorViewModel, ids: [String]) -> [String: URL?] {
        var sources: [String: URL?] = [:]
        for id in ids {
            sources[id] = editor.searchIndex.manifestSourceLookup(id)
        }
        return sources
    }
}
