import Foundation

enum SceneTagger {
    /// Maps each id to its cluster index over FootageGroups.groups — size-desc, so 0 is the biggest
    /// scene. Ids with no usable vector are absent.
    static func sceneAssignments(items: [(id: String, vector: [Float])], k: Int = 12) -> [String: Int] {
        var out: [String: Int] = [:]
        for (index, group) in FootageGroups.groups(items: items, k: k).enumerated() {
            for id in group.memberIDs { out[id] = index }
        }
        return out
    }

    static func sceneLabel(seed: Int) -> String { label(for: seed) }

    static func label(for groupIndex: Int) -> String { "Scene \(groupIndex + 1)" }
}
