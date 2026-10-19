import Foundation

enum FootageGroups {
    struct Group: Equatable, Sendable {
        let memberIDs: [String]
        let centroid: [Float]
    }

    static func groups(items: [(id: String, vector: [Float])], k: Int) -> [Group] {
        guard !items.isEmpty, k > 0 else { return [] }
        let vectors = items.map { GemmaVector.truncate($0.vector, to: 256) }
        let labels = kmeans(vectors, k: min(k, items.count))
        var buckets: [Int: (ids: [String], sum: [Float])] = [:]
        for (i, item) in items.enumerated() {
            let entry = buckets[labels[i]] ?? (ids: [], sum: [Float](repeating: 0, count: 256))
            buckets[labels[i]] = (entry.ids + [item.id], zip(entry.sum, vectors[i]).map(+))
        }
        return buckets.values
            .map { entry in
                Group(memberIDs: entry.ids, centroid: entry.sum.map { $0 / Float(max(entry.ids.count, 1)) })
            }
            .sorted { $0.memberIDs.count > $1.memberIDs.count }
    }

    static func kmeans(_ vectors: [[Float]], k: Int, iterations: Int = 25, seed: UInt64 = 7) -> [Int] {
        let n = vectors.count
        guard n > 0, k > 0, let dim = vectors.first?.count, dim > 0 else { return [] }
        let k = min(k, n)
        var rng = SplitMix64(seed: seed)
        // Farthest-first after the seeded pick: repeated RNG picks can duplicate and collapse clusters.
        var centroids = [vectors[Int(rng.next() % UInt64(n))]]
        while centroids.count < k {
            var best = 0; var bestScore = -Float.infinity
            for i in 0..<n {
                let score = -(centroids.map { dot(vectors[i], $0) }.max() ?? -Float.infinity)
                if score > bestScore { bestScore = score; best = i }
            }
            centroids.append(vectors[best])
        }
        var labels = [Int](repeating: 0, count: n)
        for _ in 0..<iterations {
            var changed = false
            for i in 0..<n {
                var best = 0; var bestScore = -Float.infinity
                for c in 0..<k {
                    let score = dot(vectors[i], centroids[c])
                    if score > bestScore { bestScore = score; best = c }
                }
                if labels[i] != best { labels[i] = best; changed = true }
            }
            guard changed else { break }
            var sums = [[Float]](repeating: [Float](repeating: 0, count: dim), count: k)
            var counts = [Int](repeating: 0, count: k)
            for i in 0..<n {
                counts[labels[i]] += 1
                for d in 0..<dim { sums[labels[i]][d] += vectors[i][d] }
            }
            for c in 0..<k where counts[c] > 0 {
                centroids[c] = sums[c].map { $0 / Float(counts[c]) }
            }
        }
        return labels
    }

    static func nearDuplicates(items: [(id: String, vector: [Float])], threshold: Float = 0.92) -> [[String]] {
        let vectors = items.map { GemmaVector.truncate($0.vector, to: 256) }
        var assigned = [Bool](repeating: false, count: items.count)
        var groups: [[String]] = []
        for i in items.indices where !assigned[i] {
            var members = [items[i].id]
            assigned[i] = true
            for j in items.indices where !assigned[j] {
                if dot(vectors[i], vectors[j]) >= threshold {
                    members.append(items[j].id)
                    assigned[j] = true
                }
            }
            if members.count > 1 { groups.append(members) }
        }
        return groups
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var out: Float = 0
        for i in a.indices where i < b.count { out += a[i] * b[i] }
        return out
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
