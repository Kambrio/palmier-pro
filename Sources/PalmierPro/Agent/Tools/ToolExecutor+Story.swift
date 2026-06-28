import Foundation

// MARK: - Input shapes

fileprivate struct LinkInput: Decodable {
    let kind: String
    let ref: String
    let label: String?
}

fileprivate struct AddStoryNodesInput: DecodableToolArgs {
    let parentId: String?
    let nodes: [NodeInput]
    static let allowedKeys: Set<String> = ["parentId", "nodes"]

    struct NodeInput: Decodable {
        let kind: String
        let title: String
        let summary: String?
        let chosen: Bool?
        let links: [LinkInput]?
    }
}

fileprivate struct SetStoryNodeInput: DecodableToolArgs {
    let nodeId: String
    let title: String?
    let summary: String?
    let chosen: Bool?
    let addLinks: [LinkInput]?
    let removeLinkIds: [String]?
    static let allowedKeys: Set<String> = ["nodeId", "title", "summary", "chosen", "addLinks", "removeLinkIds"]
}

extension ToolExecutor {

    // MARK: get_story_graph

    func getStoryGraph(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: [], path: "get_story_graph")
        let graph = editor.storyGraph
        let nodes = graph.nodes.map { Self.storyNodeJSON($0, manager: editor.storyGraphManager) }
        let payload: [String: Any] = [
            "nodes": nodes,
            "nodeCount": graph.nodes.count,
            "directionOptions": StoryTemplates.directions.map { d -> [String: Any] in
                var o: [String: Any] = ["title": d.title, "summary": d.summary]
                if let rec = StoryTemplates.recommendedStructure(forDirection: d.title) { o["recommendedStructure"] = rec }
                return o
            },
            "structureOptions": StoryTemplates.structures.map { ["title": $0.title, "summary": $0.summary] },
            "nodeKinds": StoryNodeKind.allCases.map(\.rawValue),
        ]
        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode story graph") }
        return .ok(json)
    }

    // MARK: add_story_nodes

    func addStoryNodes(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: AddStoryNodesInput = try decodeToolArgs(args, path: "add_story_nodes")
        guard !input.nodes.isEmpty else { throw ToolError("Provide at least one node in 'nodes'.") }
        if let parentId = input.parentId, editor.storyGraph.node(id: parentId) == nil {
            throw ToolError("parentId not found: \(parentId). Call get_story_graph for current node ids.")
        }
        // A single root direction is conventional; allow multiple top-level direction OPTIONS though.
        // Validate + resolve EVERYTHING before mutating, so a bad node/link doesn't leave a partial
        // (these manager edits aren't undoable). resolveLink throws on unknown/ambiguous/not-found refs.
        struct Prepared { let kind: StoryNodeKind; let title: String; let summary: String; let chosen: Bool; let links: [ResolvedLink] }
        var prepared: [Prepared] = []
        for (i, n) in input.nodes.enumerated() {
            guard let kind = StoryNodeKind(rawValue: n.kind) else {
                throw ToolError("nodes[\(i)]: invalid kind '\(n.kind)'. Expected one of: \(StoryNodeKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ToolError("nodes[\(i)]: title is empty.") }
            let links = try (n.links ?? []).map { try Self.resolveLink($0, editor: editor, path: "nodes[\(i)].links") }
            prepared.append(Prepared(kind: kind, title: title, summary: n.summary ?? "", chosen: n.chosen == true, links: links))
        }

        var created: [[String: Any]] = []
        let manager = editor.storyGraphManager
        for p in prepared {
            let id = manager.addNode(kind: p.kind, title: p.title, summary: p.summary, parentId: input.parentId, byAI: true)
            for link in p.links { manager.addLink(id: id, kind: link.kind, ref: link.ref, label: link.label) }
            if p.chosen { manager.setChosen(id: id, true) }
            created.append(["id": id, "kind": p.kind.rawValue, "title": p.title])
        }
        guard let json = Self.jsonString(["created": created]) else { throw ToolError("Failed to encode result") }
        return .ok(json)
    }

    // MARK: set_story_node

    func setStoryNode(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetStoryNodeInput = try decodeToolArgs(args, path: "set_story_node")
        guard editor.storyGraph.node(id: input.nodeId) != nil else {
            throw ToolError("nodeId not found: \(input.nodeId). Call get_story_graph for current ids.")
        }
        let manager = editor.storyGraphManager
        // Resolve links up front so a bad ref doesn't leave a half-applied edit.
        let resolvedLinks = try (input.addLinks ?? []).map { try Self.resolveLink($0, editor: editor, path: "addLinks") }
        var changed: [String] = []
        if input.title != nil || input.summary != nil {
            manager.updateNode(id: input.nodeId, title: input.title, summary: input.summary)
            if input.title != nil { changed.append("title") }
            if input.summary != nil { changed.append("summary") }
        }
        if let chosen = input.chosen { manager.setChosen(id: input.nodeId, chosen); changed.append("chosen") }
        for link in resolvedLinks { manager.addLink(id: input.nodeId, kind: link.kind, ref: link.ref, label: link.label) }
        if !resolvedLinks.isEmpty { changed.append("links") }
        for linkId in input.removeLinkIds ?? [] { manager.removeLink(id: input.nodeId, linkId: linkId) }
        if input.removeLinkIds?.isEmpty == false { changed.append("removeLinks") }

        guard !changed.isEmpty else { throw ToolError("set_story_node needs at least one field to change.") }
        guard let node = editor.storyGraph.node(id: input.nodeId) else { return .ok("Updated \(changed.joined(separator: ", ")).") }
        guard let json = Self.jsonString(["updated": changed, "node": Self.storyNodeJSON(node, manager: manager)]) else {
            throw ToolError("Failed to encode result")
        }
        return .ok(json)
    }

    // MARK: remove_story_node

    func removeStoryNode(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["nodeId"], path: "remove_story_node")
        let nodeId = try args.requireString("nodeId")
        guard editor.storyGraph.node(id: nodeId) != nil else { throw ToolError("nodeId not found: \(nodeId)") }
        let descendants = editor.storyGraph.descendantIds(of: nodeId).count
        editor.storyGraphManager.removeNode(id: nodeId)
        return .ok("Removed node \(nodeId)\(descendants > 0 ? " and \(descendants) descendant node(s)" : "").")
    }

    // MARK: - Helpers

    fileprivate struct ResolvedLink { let kind: StoryLink.Kind; let ref: String; let label: String? }

    /// Resolves a link's kind + (possibly prefixed) ref to a real element, honoring the project's
    /// unambiguous-prefix contract: exact match wins, a lone prefix match resolves, >1 throws ambiguous.
    private static func resolveLink(_ link: LinkInput, editor: EditorViewModel, path: String) throws -> ResolvedLink {
        guard let kind = StoryLink.Kind(rawValue: link.kind) else {
            throw ToolError("\(path): invalid link kind '\(link.kind)'. Expected footage, clip, caption, or document.")
        }
        switch kind {
        case .footage:
            return ResolvedLink(kind: kind, ref: try resolvePrefix(link.ref, candidates: editor.mediaAssets.map(\.id), label: "footage", path: path), label: link.label)
        case .clip:
            let ids = editor.timeline.tracks.flatMap { $0.clips.map(\.id) }
            return ResolvedLink(kind: kind, ref: try resolvePrefix(link.ref, candidates: ids, label: "clip", path: path), label: link.label)
        case .caption:
            let ids = Array(Set(editor.timeline.tracks.flatMap { $0.clips.compactMap(\.captionGroupId) }))
            return ResolvedLink(kind: kind, ref: try resolvePrefix(link.ref, candidates: ids, label: "caption group", path: path), label: link.label)
        case .document:
            return ResolvedLink(kind: kind, ref: link.ref, label: link.label)
        }
    }

    private static func resolvePrefix(_ ref: String, candidates: [String], label: String, path: String) throws -> String {
        if candidates.contains(ref) { return ref }
        let matches = candidates.filter { $0.hasPrefix(ref) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw ToolError("\(path): ambiguous \(label) ref '\(ref)' matches \(matches.count) items; use a longer id.") }
        throw ToolError("\(path): \(label) not found for ref '\(ref)'.")
    }

    private static func storyNodeJSON(_ node: StoryNode, manager: StoryGraphManager) -> [String: Any] {
        var out: [String: Any] = [
            "id": node.id,
            "kind": node.kind.rawValue,
            "title": node.title,
        ]
        if !node.summary.isEmpty { out["summary"] = node.summary }
        if let parentId = node.parentId { out["parentId"] = parentId }
        if node.chosen { out["chosen"] = true }
        if node.createdByAI { out["createdByAI"] = true }
        if !node.links.isEmpty {
            out["links"] = node.links.map { link -> [String: Any] in
                ["id": link.id, "kind": link.kind.rawValue, "ref": link.ref, "label": manager.label(for: link)]
            }
        }
        return out
    }
}
