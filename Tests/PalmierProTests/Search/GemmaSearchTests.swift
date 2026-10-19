import Testing
import Foundation
@testable import PalmierPro

@Suite struct GemmaSearchTests {
    private func storeFixture(dim: Int = 768) -> EmbeddingStore.AssetIndex {
        var query = [Float](repeating: 0.01, count: dim); query[0] = 0.99
        let rows = [EmbeddingStore.Row(time: 1, shotStart: 0, shotEnd: 4),
                    EmbeddingStore.Row(time: 5, shotStart: 4, shotEnd: 9)]
        return .init(header: .init(model: "embeddinggemma-2", modelVersion: 1, samplerVersion: 1,
                                   dim: dim, count: 2),
                     rows: rows, vectors: query + query)
    }

    @Test func frameClipAndAudioHitsRanked() {
        var clipVector = [Float](repeating: 0.01, count: 768); clipVector[0] = 0.95
        let record = ClipEmbedStore.Record(
            model: "embeddinggemma-2", modelVersion: 1, clipVector: clipVector,
            audio: [.init(start: 0, end: 30, vector: clipVector)])
        var query = [Float](repeating: 0.01, count: 768); query[0] = 0.99
        let hits = GemmaSearch.search(query: query,
                                      frameIndexes: [("a1", storeFixture())],
                                      clipRecords: [("a1", record)], limit: 10)
        #expect(hits.contains { if case .frame = $0.kind { true } else { false } })
        #expect(hits.contains { $0.kind == .clip })
        #expect(hits.contains { if case .audio = $0.kind { true } else { false } })
        #expect(hits.allSatisfy { $0.score > 0.05 })
    }

    @Test func fuseInterleavesBothRankers() {
        let sig = (0..<5).map { VisualSearch.Hit(assetID: "a\($0)", time: 1, shotStart: Double($0), shotEnd: 2, score: 1 - Float($0) * 0.01) }
        let gem = (0..<5).map { GemmaSearch.Hit(assetID: "b\($0)", kind: .frame(time: 1, shotStart: Double($0), shotEnd: 2), score: 1 - Float($0) * 0.01) }
        let fused = GemmaSearch.fuse(sig, gem, limit: 10)
        #expect(fused.count == 10)
        #expect(Set(fused.map(\.assetID)) == Set(["a0","a1","a2","a3","a4","b0","b1","b2","b3","b4"]))
        // exclusive rank-1 from each side outranks rank-5 from the other
        #expect(fused.first!.assetID == "a0" || fused.first!.assetID == "b0")
    }

    @Test func fuseRRFScoresBeatDeepSingleRanker() {
        let sig = (0..<5).map { VisualSearch.Hit(assetID: "s", time: 1, shotStart: Double($0), shotEnd: 2, score: 1 - Float($0) * 0.001) }
        let gem = [GemmaSearch.Hit(assetID: "g", kind: .frame(time: 1, shotStart: 0, shotEnd: 2), score: 0.9)]
        let fused = GemmaSearch.fuse(sig, gem, limit: 6)
        // g is rank 1 in its list (1/61) vs s rank-5 (5/65): g places above s's 5th
        let gIdx = fused.firstIndex { $0.assetID == "g" }!
        let s4 = fused.firstIndex { $0.assetID == "s" && $0.shotStart == 4 }!
        #expect(gIdx < s4)
    }

    @Test func audioMatchesRanksByCosine() {
        var voice = [Float](repeating: 0.01, count: 768); voice[1] = 0.95
        var near = [Float](repeating: 0.01, count: 768); near[1] = 0.9
        var far = [Float](repeating: 0.01, count: 768); far[2] = 0.9
        let record = ClipEmbedStore.Record(model: "embeddinggemma-2", modelVersion: 1, clipVector: nil,
                                           audio: [.init(start: 0, end: 10, vector: near),
                                                   .init(start: 10, end: 20, vector: far)])
        let matches = GemmaSearch.audioMatches(voice: voice, candidates: [("v1", record)], minScore: 0.05)
        #expect(matches.first?.start == 0)
        #expect(matches.first!.score > matches.last!.score)
    }
}
