import Foundation
import Testing
@testable import PalmierPro

@Suite struct GemmaEndToEndTests {
    /// Full pipeline with the stub embedder: index video+audio → search → fuse → cluster.
    @Test func indexThenSearchThenFuseThenCluster() async throws {
        let video = try TestMedia.makeVideo(seconds: 4, name: "gemma-e2e")
        let audio = try TestMedia.makeWAV(seconds: 2, sampleRate: 16_000, name: "gemma-e2e-audio")
        defer { [video, audio].forEach { try? FileManager.default.removeItem(at: $0) } }
        let stub = StubGemmaEmbedding()
        let vKey = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: video)!
        let aKey = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: audio)!
        defer {
            ClipEmbedStore.remove(key: vKey)
            ClipEmbedStore.remove(key: aKey)
            try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(vKey))
        }

        try await GemmaIndexer.indexVideo(indexURL: video, key: vKey, duration: 4, embedder: stub)
        try await GemmaIndexer.indexAudio(url: audio, key: aKey, embedder: stub)

        let query = try await stub.embedText("anything", task: .searchQuery)
        // Stub vectors are hash-seeded, so clip/audio cosines hover near zero; keep every kind in.
        let hits = GemmaSearch.search(
            query: query,
            frameIndexes: [("v", try EmbeddingStore.load(key: vKey))],
            clipRecords: [("v", ClipEmbedStore.load(key: vKey)!),
                          ("a", ClipEmbedStore.load(key: aKey)!)],
            minScore: -1)
        #expect(!hits.isEmpty)
        #expect(hits.contains { if case .frame = $0.kind { true } else { false } })
        #expect(hits.contains { $0.kind == .clip })
        #expect(hits.contains { if case .audio = $0.kind { true } else { false } })

        let frameHits = hits.filter { if case .frame = $0.kind { true } else { false } }
        let fused = GemmaSearch.fuse([], frameHits, limit: 5)
        #expect(!fused.isEmpty)
        let carriers: [VisualSearch.Hit] = frameHits.compactMap { hit in
            guard case let .frame(time, shotStart, shotEnd) = hit.kind else { return nil }
            return VisualSearch.Hit(assetID: hit.assetID, time: time,
                                    shotStart: shotStart, shotEnd: shotEnd, score: hit.score)
        }
        #expect(!GemmaSearch.fuse(carriers, frameHits, limit: 5).isEmpty)

        let vRecord = ClipEmbedStore.load(key: vKey)!
        let aRecord = ClipEmbedStore.load(key: aKey)!
        let groups = FootageGroups.groups(
            items: [("v", vRecord.clipVector!), ("a", aRecord.audio[0].vector)], k: 1)
        #expect(groups.count == 1)
        #expect(groups[0].memberIDs.sorted() == ["a", "v"])
    }
}

@Suite("Live Gemma sanity (opt-in)")
struct LiveGemmaSanityTests {
    /// Runs only with PALMIER_GEMMA_LIVE=1 and the BundledSpeech trait; first run downloads ~800 MB.
    @Test func queryDocumentGeometry() async throws {
        guard ProcessInfo.processInfo.environment["PALMIER_GEMMA_LIVE"] == "1" else { return }
#if BUNDLED_SPEECH
        let embedder = try await LiveGemmaEmbedderFactory.load { _ in }
        let q = try await embedder.embedText("a person walking at night", task: .searchQuery)
        let d = try await embedder.embedText("a city street at night", task: .document)
        #expect(q.count == 768)
        #expect(d.count == 768)
        #expect(abs(norm(q) - 1) < 1e-3)
        #expect(abs(norm(d) - 1) < 1e-3)
        #expect(cosine(q, d) > 0.5)
        let truncated = GemmaVector.truncate(q, to: 256)
        #expect(truncated.count == 256)
        #expect(abs(norm(truncated) - 1) < 1e-3)
#else
        #expect(Bool(true)) // live embedder needs the BundledSpeech build trait
#endif
    }

    private func norm(_ v: [Float]) -> Float {
        sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return dot / (norm(a) * norm(b))
    }
}
