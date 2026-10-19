import Accelerate
import Foundation

enum GemmaSearch {
    enum HitKind: Equatable, Sendable {
        case frame(time: Double, shotStart: Double, shotEnd: Double)
        case clip
        case audio(start: Double, end: Double)
        /// Whole-asset transcript match; carries the first 120 characters of the transcript.
        case transcriptText(snippet: String)
    }

    static let snippetLength = 120

    struct Hit: Equatable, Sendable {
        let assetID: String
        let kind: HitKind
        let score: Float
    }

    static func search(
        query: [Float],
        frameIndexes: [(assetID: String, index: EmbeddingStore.AssetIndex)],
        clipRecords: [(assetID: String, record: ClipEmbedStore.Record)],
        limit: Int = 20,
        minScore: Float = 0.05
    ) -> [Hit] {
        var hits: [Hit] = []
        for (assetID, index) in frameIndexes {
            let dim = index.header.dim
            guard dim == query.count, index.header.count > 0 else { continue }
            var scores = [Float](repeating: 0, count: index.header.count)
            vDSP_mmul(index.vectors, 1, query, 1, &scores, 1,
                      vDSP_Length(index.header.count), 1, vDSP_Length(dim))
            var bestPerShot: [Double: (row: Int, score: Float)] = [:]
            for (i, score) in scores.enumerated() {
                let shot = index.rows[i].shotStart
                if let existing = bestPerShot[shot], existing.score >= score { continue }
                bestPerShot[shot] = (i, score)
            }
            for (_, best) in bestPerShot {
                let row = index.rows[best.row]
                hits.append(Hit(assetID: assetID,
                                kind: .frame(time: row.time, shotStart: row.shotStart, shotEnd: row.shotEnd),
                                score: best.score))
            }
        }
        for (assetID, record) in clipRecords {
            if let clip = record.clipVector, clip.count == query.count {
                let score = cosine(clip, query)
                if score >= minScore { hits.append(Hit(assetID: assetID, kind: .clip, score: score)) }
            }
            for chunk in record.audio where chunk.vector.count == query.count {
                let score = cosine(chunk.vector, query)
                if score >= minScore {
                    hits.append(Hit(assetID: assetID, kind: .audio(start: chunk.start, end: chunk.end), score: score))
                }
            }
            if let transcript = record.transcriptVector, transcript.count == query.count {
                let score = cosine(transcript, query)
                if score >= minScore {
                    let snippet = String((record.transcriptText ?? "").prefix(snippetLength))
                    hits.append(Hit(assetID: assetID, kind: .transcriptText(snippet: snippet), score: score))
                }
            }
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// Reciprocal-rank fusion (k = 60) over frame hits keyed by (assetID, shotStart).
    /// RRF weights order the result; each Hit carries its best cosine so the UI shows similarity.
    static func fuse(_ siglip: [VisualSearch.Hit], _ gemma: [GemmaSearch.Hit], limit: Int) -> [VisualSearch.Hit] {
        struct Key: Hashable { let assetID: String; let shot: Double }
        let k: Float = 60
        var scores: [Key: Float] = [:]
        var carrier: [Key: VisualSearch.Hit] = [:]
        for (rank, hit) in siglip.enumerated() {
            let key = Key(assetID: hit.assetID, shot: hit.shotStart)
            scores[key, default: 0] += 1 / (k + Float(rank + 1))
            carrier[key] = hit
        }
        for (rank, hit) in gemma.enumerated() {
            guard case let .frame(_, shotStart, shotEnd) = hit.kind else { continue }
            let key = Key(assetID: hit.assetID, shot: shotStart)
            scores[key, default: 0] += 1 / (k + Float(rank + 1))
            if let existing = carrier[key], existing.score >= hit.score { continue }
            carrier[key] = VisualSearch.Hit(assetID: hit.assetID, time: hitTime(hit),
                                            shotStart: shotStart, shotEnd: shotEnd, score: hit.score)
        }
        return scores
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { carrier[$0.key] }
    }

    static func audioMatches(
        voice: [Float],
        candidates: [(assetID: String, record: ClipEmbedStore.Record)],
        limit: Int = 5,
        minScore: Float = 0.3
    ) -> [(assetID: String, start: Double, end: Double, score: Float)] {
        var out: [(assetID: String, start: Double, end: Double, score: Float)] = []
        for (assetID, record) in candidates {
            for chunk in record.audio where chunk.vector.count == voice.count {
                let score = cosine(chunk.vector, voice)
                if score >= minScore {
                    out.append((assetID: assetID, start: chunk.start, end: chunk.end, score: score))
                }
            }
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(limit))
    }

    private static func hitTime(_ hit: Hit) -> Double {
        if case let .frame(time, _, _) = hit.kind { return time }
        return 0
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0; var na: Float = 0; var nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / (sqrt(na) * sqrt(nb) + 1e-9)
    }
}
