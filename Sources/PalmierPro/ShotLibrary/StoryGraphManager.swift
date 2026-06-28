import CoreGraphics
import Foundation

/// Owns the story-development graph: CRUD over nodes, branching from templates, linking nodes to
/// real project elements (footage / clips / captions / documents), and persistence. Shared by the
/// graph UI and the agent (MCP) tools.
@MainActor
@Observable
final class StoryGraphManager {
    private unowned let editor: EditorViewModel

    init(editor: EditorViewModel) { self.editor = editor }

    var graph: StoryGraph { editor.storyGraph }

    /// The most recently added node (UI or agent). Bumped with a token so the canvas can re-focus
    /// its camera even when the same id would otherwise not register as a change.
    private(set) var focusRequest: (id: String, token: Int)?
    private var focusToken = 0

    /// Move the canvas camera to a node (e.g. after the agent adds or selects one).
    func requestFocus(id: String) {
        guard editor.storyGraph.node(id: id) != nil else { return }
        focusToken &+= 1
        focusRequest = (id, focusToken)
    }

    // MARK: - Mutations

    @discardableResult
    func addNode(kind: StoryNodeKind, title: String, summary: String = "", parentId: String? = nil, byAI: Bool = false) -> String {
        if let parentId, editor.storyGraph.node(id: parentId) == nil { return "" }
        var node = StoryNode(kind: kind, title: title, summary: summary, parentId: parentId)
        node.createdByAI = byAI
        editor.storyGraph.nodes.append(node)
        invalidateLayout()
        requestFocus(id: node.id)
        persist()
        return node.id
    }

    /// Add the template-suggested option children under a parent (nil → top-level directions).
    @discardableResult
    func addSuggestedChildren(parentId: String?) -> [String] {
        let parent = parentId.flatMap { editor.storyGraph.node(id: $0) }
        let suggestion = StoryTemplates.childSuggestions(forParent: parent)
        let ids = suggestion.templates.map { t in
            addNode(kind: suggestion.kind, title: t.title, summary: t.summary, parentId: parentId)
        }
        // Focus the first of the batch (top of the new column) rather than the last.
        if let first = ids.first { requestFocus(id: first) }
        return ids
    }

    func updateNode(id: String, title: String? = nil, summary: String? = nil) {
        mutate(id) {
            if let title { $0.title = title }
            if let summary { $0.summary = summary }
        }
    }

    /// Mark a node chosen; clears the chosen flag on its siblings (one option per branch).
    func setChosen(id: String, _ chosen: Bool) {
        guard let node = editor.storyGraph.node(id: id) else { return }
        for i in editor.storyGraph.nodes.indices {
            let n = editor.storyGraph.nodes[i]
            if n.id == id { editor.storyGraph.nodes[i].chosen = chosen }
            else if chosen, n.parentId == node.parentId, n.kind == node.kind { editor.storyGraph.nodes[i].chosen = false }
        }
        persist()
    }

    func setPosition(id: String, _ point: CGPoint) {
        mutate(id) { $0.position = point }
        invalidateLayout()
    }

    func addLink(id: String, kind: StoryLink.Kind, ref: String, label: String? = nil) {
        mutate(id) { node in
            guard !node.links.contains(where: { $0.kind == kind && $0.ref == ref }) else { return }
            node.links.append(StoryLink(kind: kind, ref: ref, label: label))
        }
    }

    func removeLink(id: String, linkId: String) {
        mutate(id) { $0.links.removeAll { $0.id == linkId } }
    }

    func removeNode(id: String) {
        editor.storyGraph.remove(id: id)
        invalidateLayout()
        persist()
    }

    func clear() {
        editor.storyGraph = StoryGraph()
        invalidateLayout()
        persist()
    }

    private func mutate(_ id: String, _ change: (inout StoryNode) -> Void) {
        guard let i = editor.storyGraph.nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&editor.storyGraph.nodes[i])
        persist()
    }

    private func persist() { editor.onPersistentStateChanged?() }

    // MARK: - Timeline preview

    /// Builds the "Preview story on the timeline" highlight bands: for each beat/block node with
    /// footage/clip links, find the timeline clips those links resolve to and tag their frame spans
    /// with the beat's title + a cycling color. Returns how many bands were placed and which beats
    /// have no footage on the timeline yet. Sets `editor.storyPreviewBands`.
    @discardableResult
    func buildTimelinePreview() -> (placed: Int, unplaced: [String]) {
        var bands: [StoryPreviewBand] = []
        var unplaced: [String] = []
        let beats = editor.storyGraph.nodes.filter { ($0.kind == .beat || $0.kind == .block) && !$0.links.isEmpty }
        for (i, beat) in beats.enumerated() {
            var found = false
            for link in beat.links {
                switch link.kind {
                case .footage:
                    for track in editor.timeline.tracks {
                        for clip in track.clips where clip.mediaRef == link.ref {
                            bands.append(StoryPreviewBand(beatId: beat.id, title: beat.title, startFrame: clip.startFrame, endFrame: clip.endFrame, colorIndex: i))
                            found = true
                        }
                    }
                case .clip:
                    if let clip = editor.clipFor(id: link.ref) {
                        bands.append(StoryPreviewBand(beatId: beat.id, title: beat.title, startFrame: clip.startFrame, endFrame: clip.endFrame, colorIndex: i))
                        found = true
                    }
                case .caption, .document:
                    break
                }
            }
            if !found { unplaced.append(beat.title) }
        }
        editor.storyPreviewBands = bands
        return (bands.count, unplaced)
    }

    func clearTimelinePreview() { editor.storyPreviewBands = [] }
    var hasTimelinePreview: Bool { !editor.storyPreviewBands.isEmpty }

    // MARK: - Linking helpers

    /// A human label for a link target (footage name from the Shot Library / media, etc.).
    func label(for link: StoryLink) -> String {
        if let label = link.label, !label.isEmpty { return label }
        switch link.kind {
        case .footage:
            if let name = editor.shotLibrary.entry(assetId: link.ref)?.displayName, !name.isEmpty { return name }
            return editor.mediaResolver.displayName(for: link.ref)
        case .clip:
            if let clip = editor.clipFor(id: link.ref) { return editor.clipDisplayLabel(for: clip) }
            return "Clip"
        case .caption:  return "Captions"
        case .document: return link.ref
        }
    }

    // MARK: - Layered layout

    /// Auto-positions nodes that have no manual position: columns by depth, rows within a column.
    /// Returns positions for every node so the canvas can draw without mutating the model.
    // Layout is recomputed only when the graph changes — never per scroll/render. The view's body
    // re-evaluates on every scroll tick, so an uncached O(nodes×depth) layout there was a scroll cost.
    @ObservationIgnored private var cachedLayout: [String: CGPoint]?
    @ObservationIgnored private var cachedLayoutKey: (cols: CGFloat, rows: CGFloat)?

    func invalidateLayout() { cachedLayout = nil }

    func layout(columnWidth: CGFloat = 260, rowHeight: CGFloat = 110) -> [String: CGPoint] {
        if let cached = cachedLayout, let key = cachedLayoutKey,
           key.cols == columnWidth, key.rows == rowHeight {
            return cached
        }
        let nodes = editor.storyGraph.nodes
        var byDepth: [Int: [StoryNode]] = [:]
        for n in nodes { byDepth[editor.storyGraph.depth(of: n), default: []].append(n) }
        var positions: [String: CGPoint] = [:]
        for (depth, group) in byDepth {
            // Preserve creation order (templates add in canonical order, e.g. travel before
            // tutorial) — alphabetical sorting buried important options below the fold.
            let ordered = group
            for (i, node) in ordered.enumerated() {
                if let p = node.position {
                    positions[node.id] = p
                } else {
                    // Stable, non-negative grid: column by depth, row by sibling order.
                    positions[node.id] = CGPoint(x: CGFloat(depth) * columnWidth + 40,
                                                 y: CGFloat(i) * rowHeight + 40)
                }
            }
        }
        cachedLayout = positions
        cachedLayoutKey = (columnWidth, rowHeight)
        return positions
    }
}
