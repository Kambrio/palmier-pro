import CoreGraphics
import Foundation

/// A level in the story tree, from the project's overall direction down to concrete building blocks.
enum StoryNodeKind: String, Codable, Sendable, CaseIterable {
    case direction   // root: genre / format + angle
    case structure   // a story structure (three-act, hook-build-payoff, …)
    case act         // a major movement
    case beat        // a concrete moment ("cold-open hook")
    case block       // a building block inside a beat (a shot, a VO line, a title)

    var displayName: String {
        switch self {
        case .direction: "Direction"
        case .structure: "Structure"
        case .act:       "Act"
        case .beat:      "Beat"
        case .block:     "Block"
        }
    }

    /// The natural child level when branching deeper.
    var childKind: StoryNodeKind {
        switch self {
        case .direction: .structure
        case .structure: .act
        case .act:       .beat
        case .beat:      .block
        case .block:     .block
        }
    }
}

/// A link from a story node to a real project element — the footage, caption, or document that fills it.
struct StoryLink: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case footage, clip, caption, document }
    var id: String = UUID().uuidString
    var kind: Kind
    var ref: String          // mediaRef / clipId / captionGroupId / document filename
    var label: String?

    init(kind: Kind, ref: String, label: String? = nil) {
        self.kind = kind; self.ref = ref; self.label = label
    }
}

/// One node in the story graph: an option for how the story could go at its level.
struct StoryNode: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var kind: StoryNodeKind
    var title: String
    var summary: String = ""
    var parentId: String?       // nil only for the root direction
    /// The user/AI picked this option over its siblings.
    var chosen: Bool = false
    var links: [StoryLink] = []
    /// Manual layout override (canvas point); nil → auto-laid-out by depth.
    var position: CGPoint?
    var createdByAI: Bool = false

    init(kind: StoryNodeKind, title: String, summary: String = "", parentId: String? = nil) {
        self.kind = kind; self.title = title; self.summary = summary; self.parentId = parentId
    }

    // Tolerant decode so the schema can grow without breaking older projects.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decodeIfPresent(StoryNodeKind.self, forKey: .kind) ?? .beat
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        chosen = try c.decodeIfPresent(Bool.self, forKey: .chosen) ?? false
        links = try c.decodeIfPresent([StoryLink].self, forKey: .links) ?? []
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position)
        createdByAI = try c.decodeIfPresent(Bool.self, forKey: .createdByAI) ?? false
    }
}

/// Project-scoped story-development tree, persisted as `story-graph.json`.
struct StoryGraph: Codable, Sendable, Equatable {
    var version: Int = 1
    var nodes: [StoryNode] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        nodes = try c.decodeIfPresent([StoryNode].self, forKey: .nodes) ?? []
    }

    var isEmpty: Bool { nodes.isEmpty }
    var root: StoryNode? { nodes.first { $0.parentId == nil } }
    func node(id: String) -> StoryNode? { nodes.first { $0.id == id } }
    func children(of id: String) -> [StoryNode] { nodes.filter { $0.parentId == id } }

    /// Depth of a node from the root (root = 0). Cycle-safe via a visited set (a corrupt/hand-edited
    /// graph could contain a parent cycle the tolerant decoder happily loads).
    func depth(of node: StoryNode) -> Int {
        var d = 0
        var current = node
        var seen: Set<String> = [node.id]
        while let parentId = current.parentId, let parent = self.node(id: parentId), seen.insert(parentId).inserted {
            d += 1; current = parent
        }
        return d
    }

    /// All descendant ids of a node (for pruning a branch). Cycle-safe.
    func descendantIds(of id: String) -> [String] {
        var out: [String] = []
        var seen: Set<String> = [id]
        var stack = children(of: id).map(\.id)
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            out.append(next)
            stack.append(contentsOf: children(of: next).map(\.id))
        }
        return out
    }

    mutating func upsert(_ node: StoryNode) {
        if let i = nodes.firstIndex(where: { $0.id == node.id }) { nodes[i] = node }
        else { nodes.append(node) }
    }

    /// Removes a node and its whole subtree.
    mutating func remove(id: String) {
        let doomed = Set([id] + descendantIds(of: id))
        nodes.removeAll { doomed.contains($0.id) }
    }
}

/// A timeline highlight band tying a story beat to a clip's frame span — drawn by "Preview story on
/// the timeline" so the user can see which sections each beat's footage occupies. Not persisted.
struct StoryPreviewBand: Equatable, Sendable, Identifiable {
    let id = UUID()
    let beatId: String
    let title: String
    let startFrame: Int
    let endFrame: Int
    let colorIndex: Int
}
