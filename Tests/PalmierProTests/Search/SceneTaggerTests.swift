import Testing
import Foundation
@testable import PalmierPro

@Suite struct SceneTaggerTests {
    // FootageGroups truncates to 256 dims and drops shorter vectors, so fixtures stay above 256.
    private func unit(_ direction: Int, dim: Int = 300) -> [Float] {
        var v = [Float](repeating: 0.02, count: dim); v[direction] = 0.98
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / n }
    }

    private func fixture() -> [(id: String, vector: [Float])] {
        [
            ("a1", unit(0)), ("a2", unit(0)), ("a3", unit(0)), ("a4", unit(0)),
            ("b1", unit(200)), ("b2", unit(200)),
            ("c1", unit(250)), ("c2", unit(250)), ("c3", unit(250)),
        ]
    }

    @Test func partitionsIdsAcrossGroups() {
        let assignments = SceneTagger.sceneAssignments(items: fixture(), k: 3)
        #expect(assignments.count == 9)
        #expect(assignments["a1"] == assignments["a2"] && assignments["a2"] == assignments["a3"] && assignments["a3"] == assignments["a4"])
        #expect(assignments["b1"] == assignments["b2"])
        #expect(assignments["c1"] == assignments["c2"] && assignments["c2"] == assignments["c3"])
        #expect(Set(assignments.values).count == 3)
        #expect(assignments["a1"] == 0, "index 0 is the biggest scene")
    }

    @Test func idsWithoutUsableVectorAreAbsent() {
        let items: [(id: String, vector: [Float])] = [
            ("a1", unit(0)), ("a2", unit(0)),
            ("short", [Float](repeating: 0.5, count: 64)),
            ("empty", []),
        ]
        let assignments = SceneTagger.sceneAssignments(items: items, k: 2)
        #expect(assignments.keys.sorted() == ["a1", "a2"])
    }

    @Test func fewerThanTwoUsableItemsYieldEmptyDict() {
        #expect(SceneTagger.sceneAssignments(items: []).isEmpty)
        #expect(SceneTagger.sceneAssignments(items: [("solo", unit(0))]).isEmpty)
        #expect(SceneTagger.sceneAssignments(items: [("solo", unit(0)), ("short", [Float](repeating: 0.1, count: 10))]).isEmpty)
    }

    @Test func deterministicAcrossCalls() {
        #expect(SceneTagger.sceneAssignments(items: fixture(), k: 3) == SceneTagger.sceneAssignments(items: fixture(), k: 3))
    }

    @Test func labelsAreStableAndIndexedFromOne() {
        #expect(SceneTagger.sceneLabel(seed: 0) == "Scene 1")
        #expect(SceneTagger.label(for: 11) == "Scene 12")
        #expect(SceneTagger.sceneLabel(seed: 5) == SceneTagger.label(for: 5))
    }
}
