import Testing
import Foundation
@testable import PalmierPro

@Suite struct FootageGroupsTests {
    private func unit(_ direction: Int, dim: Int = 768) -> [Float] {
        var v = [Float](repeating: 0.02, count: dim); v[direction] = 0.98
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / n }
    }

    @Test func kmeansSeparatesTwoClusters() {
        var vectors: [[Float]] = []
        for _ in 0..<5 { vectors.append(unit(0)) }
        for _ in 0..<5 { vectors.append(unit(400)) }
        let labels = FootageGroups.kmeans(vectors, k: 2)
        #expect(Set(labels).count == 2)
        #expect(labels.prefix(5).allSatisfy { $0 == labels[0] })
        #expect(labels.suffix(5).allSatisfy { $0 == labels[5] })
    }

    @Test func kmeansDeterministic() {
        let vectors = (0..<10).map { unit($0 * 30) }
        #expect(FootageGroups.kmeans(vectors, k: 3) == FootageGroups.kmeans(vectors, k: 3))
    }

    @Test func groupsKeepIds() {
        let items: [(id: String, vector: [Float])] = [
            ("a", unit(0)), ("b", unit(0)), ("c", unit(500)),
        ]
        let groups = FootageGroups.groups(items: items, k: 2)
        #expect(groups.count == 2)
        #expect(groups.first!.memberIDs.count == 2 || groups.last!.memberIDs.count == 2)
        #expect(groups.flatMap(\.memberIDs).sorted() == ["a", "b", "c"])
    }

    @Test func nearDuplicatesPairsCloseVectors() {
        var near = unit(0); near[1] = 0.4
        let n = sqrt(near.reduce(0) { $0 + $1 * $1 }); near = near.map { $0 / n }
        let items: [(id: String, vector: [Float])] = [("x", unit(0)), ("y", near), ("z", unit(600))]
        let dups = FootageGroups.nearDuplicates(items: items, threshold: 0.9)
        #expect(dups.contains { $0.sorted() == ["x", "y"] })
        #expect(!dups.flatMap({ $0 }).contains("z"))
    }
}
