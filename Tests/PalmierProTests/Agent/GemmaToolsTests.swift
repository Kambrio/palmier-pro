import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

@Suite("gemma agent tools")
@MainActor
struct GemmaToolsTests {
    // MARK: Executor path — capability gate and argument validation

    @Test func capabilityMissingReturnsEnableError() async {
        // GemmaModelManager.shared is disabled in the test process, so all three
        // tools must refuse with the enable action, never empty success.
        let h = ToolHarness()
        let voice = h.addAsset(type: .audio)
        h.addAsset(type: .video)
        let args: [String: [String: Any]] = [
            "find_moments": ["query": "a harbor at dusk"],
            "cluster_footage": [:],
            "match_audio": ["voiceAssetId": voice.id],
        ]
        for tool in ["find_moments", "cluster_footage", "match_audio"] {
            let result = await h.runRaw(tool, args: args[tool] ?? [:])
            #expect(result.isError, "\(tool) must error when the model is off")
            let text = ToolHarness.textOf(result)
            #expect(text.contains("EmbeddingGemma 2"), "\(tool) error names the capability")
            #expect(text.contains("Settings"), "\(tool) error names the enable action")
        }
    }

    @Test func rejectsBadArgs() async {
        let h = ToolHarness()
        #expect(await h.runRaw("find_moments", args: [:]).isError)
        #expect(await h.runRaw("find_moments", args: ["query": "   "]).isError)
        #expect(await h.runRaw("find_moments", args: ["query": "a dog", "bogus": 1]).isError)
        #expect(await h.runRaw("match_audio", args: [:]).isError)
        #expect(await h.runRaw("match_audio", args: ["voiceAssetId": "nope"]).isError)
        #expect(await h.runRaw("cluster_footage", args: ["nope": 1]).isError)
    }

    // MARK: GemmaToolCore — find_moments

    @Test func findMomentsReturnsKindsTimesAndScores() async throws {
        let url = try seededFile("video.mov")
        let key = storeKey(url)
        defer { cleanup(url: url, key: key) }

        var query = unitVector(axis: 0)
        var weaker = unitVector(axis: 0); weaker[0] = 0.5
        let unrelated = unitVector(axis: 1)

        // Two frames in one shot: only the best survives; the unrelated clip
        // vector scores ~0 and is filtered by the clip minimum.
        try EmbeddingStore.save(
            header: .init(
                model: GemmaIndexer.modelName, modelVersion: GemmaIndexer.modelVersion,
                samplerVersion: FrameSampler.samplerVersion, dim: 768, count: 2),
            rows: [.init(time: 1, shotStart: 0, shotEnd: 2),
                   .init(time: 3, shotStart: 0, shotEnd: 2)],
            vectors: query + weaker, key: key)
        try ClipEmbedStore.save(
            .init(model: GemmaIndexer.modelName, modelVersion: GemmaIndexer.modelVersion,
                  clipVector: unrelated, audio: [.init(start: 0, end: 5, vector: query)]),
            key: key)

        let result = try await GemmaToolCore.findMoments(
            query: "a harbor at dusk", embedder: FixedVectorEmbedder(vector: query),
            candidates: [(id: "a1", url: url)], sources: [:], limit: 20, fps: 30)
        #expect(result.isError == false)

        let obj = try jsonObject(result)
        #expect(obj["timelineFps"] as? Int == 30)
        let moments = try #require(obj["moments"] as? [[String: Any]])
        #expect(moments.count == 2)

        let frame = try #require(moments.first { $0["kind"] as? String == "frame" })
        #expect(frame["assetId"] as? String == "a1")
        #expect((frame["time"] as? Double) == 1)
        #expect((frame["start"] as? Double) == 0)
        #expect((frame["end"] as? Double) == 2)
        let frameScore = try #require(frame["score"] as? Double)
        #expect(abs(frameScore - 1) < 0.001)

        let audio = try #require(moments.first { $0["kind"] as? String == "audio" })
        #expect((audio["start"] as? Double) == 0)
        #expect((audio["end"] as? Double) == 5)
        #expect(audio["time"] == nil)
        for moment in moments {
            let score = try #require(moment["score"] as? Double)
            #expect(score >= 0 && score <= 1)
        }
    }

    @Test func findMomentsWithoutIndexesIsExplicitNoOp() async throws {
        let url = try seededFile("unindexed.mov")
        let key = storeKey(url)
        defer { cleanup(url: url, key: key) }

        let result = try await GemmaToolCore.findMoments(
            query: "anything", embedder: FixedVectorEmbedder(vector: unitVector(axis: 0)),
            candidates: [(id: "a1", url: url)], sources: [:], limit: 20, fps: 30)
        #expect(result.isError == false)
        let obj = try jsonObject(result)
        #expect((obj["moments"] as? [Any])?.isEmpty == true)
        #expect((obj["note"] as? String)?.contains("indexing") == true)
    }

    // MARK: GemmaToolCore — cluster_footage

    @Test func clusterFootageReturnsGroupsAndDuplicates() throws {
        let urls = try (0..<4).map { try seededFile("v\($0).mov") }
        let keys = urls.map { storeKey($0) }
        defer { for (url, key) in zip(urls, keys) { cleanup(url: url, key: key) } }

        let pairA = unitVector(axis: 0)
        let pairB = unitVector(axis: 1)
        let ids = ["v0", "v1", "v2", "v3"]
        let vectors = [pairA, pairA, pairB, pairB]
        for (i, url) in urls.enumerated() {
            try ClipEmbedStore.save(
                .init(model: GemmaIndexer.modelName, modelVersion: GemmaIndexer.modelVersion,
                      clipVector: vectors[i], audio: []),
                key: keys[i])
        }

        let result = try GemmaToolCore.clusterFootage(
            candidates: zip(ids, urls).map { (id: $0.0, url: $0.1) }, totalVideoAssets: 6)
        #expect(result.isError == false)
        let obj = try jsonObject(result)

        let groups = try #require(obj["groups"] as? [[String: Any]])
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { ($0["size"] as? Int) == 2 })
        let groupedIds = Set(groups.flatMap { ($0["memberIds"] as? [String]) ?? [] })
        #expect(groupedIds == Set(ids))

        let takes = try #require(obj["similarTakes"] as? [[String]])
        #expect(takes.count == 2)
        #expect(Set(takes.flatMap { $0 }) == Set(ids))

        let coverage = try #require(obj["coverage"] as? [String: Any])
        #expect(coverage["assets"] as? Int == 6)
        #expect(coverage["grouped"] as? Int == 4)
    }

    @Test func clusterFootageWithoutEmbeddingsIsExplicitNoOp() throws {
        let url = try seededFile("novectors.mov")
        let key = storeKey(url)
        defer { cleanup(url: url, key: key) }

        let result = try GemmaToolCore.clusterFootage(
            candidates: [(id: "v0", url: url)], totalVideoAssets: 1)
        #expect(result.isError == false)
        let obj = try jsonObject(result)
        #expect((obj["groups"] as? [Any])?.isEmpty == true)
        #expect((obj["similarTakes"] as? [Any])?.isEmpty == true)
        let coverage = try #require(obj["coverage"] as? [String: Any])
        #expect(coverage["assets"] as? Int == 1)
        #expect(coverage["grouped"] as? Int == 0)
        #expect((obj["note"] as? String)?.contains("indexing") == true)
    }

    // MARK: GemmaToolCore — match_audio

    @Test func matchAudioRanksSimilarMoments() throws {
        let voiceURL = try seededFile("voice.wav")
        let nearURL = try seededFile("near.mov")
        let farURL = try seededFile("far.mov")
        let voiceKey = storeKey(voiceURL), nearKey = storeKey(nearURL), farKey = storeKey(farURL)
        defer {
            cleanup(url: voiceURL, key: voiceKey)
            cleanup(url: nearURL, key: nearKey)
            cleanup(url: farURL, key: farKey)
        }

        let voice = unitVector(axis: 0)
        try ClipEmbedStore.save(
            .init(model: GemmaIndexer.modelName, modelVersion: GemmaIndexer.modelVersion,
                  clipVector: nil, audio: [.init(start: 0, end: 2, vector: voice)]),
            key: voiceKey)
        try ClipEmbedStore.save(
            .init(model: GemmaIndexer.modelName, modelVersion: GemmaIndexer.modelVersion,
                  clipVector: nil, audio: [.init(start: 10, end: 12, vector: voice)]),
            key: nearKey)
        try ClipEmbedStore.save(
            .init(model: GemmaIndexer.modelName, modelVersion: GemmaIndexer.modelVersion,
                  clipVector: nil, audio: [.init(start: 20, end: 22, vector: unitVector(axis: 1))]),
            key: farKey)

        // The voice asset itself is in the candidate list and must be excluded.
        let result = try GemmaToolCore.matchAudio(
            voiceID: "voice", voiceURL: voiceURL,
            candidates: [(id: "voice", url: voiceURL), (id: "near", url: nearURL), (id: "far", url: farURL)],
            sources: [:], limit: 5, fps: 24)
        #expect(result.isError == false)
        let obj = try jsonObject(result)
        #expect(obj["voiceAssetId"] as? String == "voice")
        #expect(obj["timelineFps"] as? Int == 24)
        let matches = try #require(obj["matches"] as? [[String: Any]])
        #expect(matches.count == 1)
        #expect(matches[0]["videoAssetId"] as? String == "near")
        #expect((matches[0]["start"] as? Double) == 10)
        #expect((matches[0]["end"] as? Double) == 12)
        #expect(abs((matches[0]["score"] as? Double ?? 0) - 1) < 0.001)
    }

    @Test func matchAudioWithoutMatchesIsExplicitNoOp() throws {
        let voiceURL = try seededFile("solo.wav")
        let farURL = try seededFile("only-far.mov")
        let voiceKey = storeKey(voiceURL), farKey = storeKey(farURL)
        defer {
            cleanup(url: voiceURL, key: voiceKey)
            cleanup(url: farURL, key: farKey)
        }
        try ClipEmbedStore.save(
            .init(model: GemmaIndexer.modelName, modelVersion: GemmaIndexer.modelVersion,
                  clipVector: nil, audio: [.init(start: 0, end: 2, vector: unitVector(axis: 0))]),
            key: voiceKey)
        try ClipEmbedStore.save(
            .init(model: GemmaIndexer.modelName, modelVersion: GemmaIndexer.modelVersion,
                  clipVector: nil, audio: [.init(start: 20, end: 22, vector: unitVector(axis: 1))]),
            key: farKey)

        let result = try GemmaToolCore.matchAudio(
            voiceID: "voice", voiceURL: voiceURL,
            candidates: [(id: "far", url: farURL)], sources: [:], limit: 5, fps: 30)
        #expect(result.isError == false)
        let obj = try jsonObject(result)
        #expect((obj["matches"] as? [Any])?.isEmpty == true)
        #expect(obj["note"] as? String == "no similar audio moments found")
    }

    @Test func matchAudioWithoutVoiceRecordNamesAsset() throws {
        let voiceURL = try seededFile("silent.wav")
        let key = storeKey(voiceURL)
        defer { cleanup(url: voiceURL, key: key) }

        let result = try GemmaToolCore.matchAudio(
            voiceID: "voice", voiceURL: voiceURL,
            candidates: [], sources: [:], limit: 5, fps: 30)
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("voice"))
    }
}

// MARK: - Fixtures

private extension GemmaToolsTests {
    /// Real temp file so EmbeddingStore.key(for:) can stat it; content is irrelevant.
    func seededFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma-tool-\(UUID().uuidString)-\(name)")
        try Data("stub".utf8).write(to: url)
        return url
    }

    func storeKey(_ url: URL) -> String {
        GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: url)!
    }

    func cleanup(url: URL, key: String) {
        ClipEmbedStore.remove(key: key)
        try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key))
        try? FileManager.default.removeItem(at: url)
    }

    func unitVector(axis: Int, dim: Int = 768) -> [Float] {
        var vector = [Float](repeating: 0, count: dim)
        vector[axis] = 1
        return vector
    }

    func jsonObject(_ result: ToolResult) throws -> [String: Any] {
        guard case let .text(text) = result.content.first,
              let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ToolError("expected JSON object payload")
        }
        return obj
    }
}

/// Returns one fixed vector for every embed call; the gemma tool path only uses embedText.
private final class FixedVectorEmbedder: GemmaEmbedding {
    let dim: Int
    private let vector: [Float]

    init(vector: [Float]) {
        self.vector = vector
        self.dim = vector.count
    }

    func embedText(_ text: String, task: GemmaTask) async throws -> [Float] { vector }
    func embedImages(_ images: [CGImage]) async throws -> [[Float]] { images.map { _ in vector } }
    func embedVideo(_ frames: [CGImage]) async throws -> [Float] { vector }
    func embedAudio(_ samples: [Float], sampleRate: Int) async throws -> [Float] { vector }
}
