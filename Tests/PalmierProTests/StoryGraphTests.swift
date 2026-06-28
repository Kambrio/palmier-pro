import Testing
import Foundation
@testable import PalmierPro

struct StoryGraphModelTests {
    @Test func roundTripsAndToleratesMissingFields() throws {
        var graph = StoryGraph()
        var dir = StoryNode(kind: .direction, title: "Cinematic life vlog")
        dir.chosen = true
        graph.nodes.append(dir)
        var beat = StoryNode(kind: .beat, title: "Cold-open hook", parentId: dir.id)
        beat.links = [StoryLink(kind: .footage, ref: "asset-1", label: "Sunset")]
        graph.nodes.append(beat)

        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(StoryGraph.self, from: data)
        #expect(decoded.nodes.count == 2)
        #expect(decoded.root?.title == "Cinematic life vlog")
        #expect(decoded.children(of: dir.id).first?.title == "Cold-open hook")
        #expect(decoded.node(id: beat.id)?.links.first?.ref == "asset-1")

        // Minimal node JSON still decodes.
        let minimal = #"{"nodes":[{"id":"x","kind":"beat","title":"t"}]}"#
        let g2 = try JSONDecoder().decode(StoryGraph.self, from: Data(minimal.utf8))
        #expect(g2.node(id: "x")?.summary == "")
        #expect(g2.node(id: "x")?.links.isEmpty == true)
    }

    @Test func depthAndDescendantsAndRemoveSubtree() {
        var graph = StoryGraph()
        let root = StoryNode(kind: .direction, title: "root")
        graph.nodes.append(root)
        let structure = StoryNode(kind: .structure, title: "s", parentId: root.id)
        graph.nodes.append(structure)
        let beat = StoryNode(kind: .beat, title: "b", parentId: structure.id)
        graph.nodes.append(beat)

        #expect(graph.depth(of: root) == 0)
        #expect(graph.depth(of: beat) == 2)
        #expect(Set(graph.descendantIds(of: root.id)) == Set([structure.id, beat.id]))

        graph.remove(id: structure.id)
        #expect(graph.nodes.count == 1)           // structure + its beat removed
        #expect(graph.node(id: root.id) != nil)
    }

    @Test func cyclicGraphDoesNotHang() {
        // A corrupt/hand-edited graph could carry a parent cycle the tolerant decoder loads.
        var graph = StoryGraph()
        var a = StoryNode(kind: .direction, title: "a")
        let b = StoryNode(kind: .structure, title: "b", parentId: a.id)
        a.parentId = b.id                          // a ↔ b cycle
        graph.nodes = [a, b]
        // These must terminate (visited-set guarded), not spin forever.
        #expect(graph.descendantIds(of: a.id).count <= 2)
        #expect(graph.depth(of: a) <= 2)
        graph.remove(id: a.id)
        #expect(graph.nodes.isEmpty)
    }
}

@MainActor
struct StoryGraphManagerTests {
    @Test func addBranchChooseLinkRemove() {
        let editor = EditorViewModel()
        let m = editor.storyGraphManager

        // Top-level direction options from templates.
        let dirIds = m.addSuggestedChildren(parentId: nil)
        #expect(dirIds.count == StoryTemplates.directions.count)
        #expect(editor.storyGraph.nodes.allSatisfy { $0.kind == .direction })

        // Choosing one clears chosen on its siblings.
        m.setChosen(id: dirIds[0], true)
        m.setChosen(id: dirIds[1], true)
        #expect(editor.storyGraph.node(id: dirIds[0])?.chosen == false)
        #expect(editor.storyGraph.node(id: dirIds[1])?.chosen == true)

        // Branch into structure options under the chosen direction.
        let structIds = m.addSuggestedChildren(parentId: dirIds[1])
        #expect(!structIds.isEmpty)
        #expect(editor.storyGraph.children(of: dirIds[1]).count == structIds.count)

        // Link footage to a node; de-dupes identical links.
        let beatId = m.addNode(kind: .beat, title: "Hook", parentId: structIds[0])
        m.addLink(id: beatId, kind: .footage, ref: "asset-1", label: "Shot A")
        m.addLink(id: beatId, kind: .footage, ref: "asset-1", label: "Shot A")
        #expect(editor.storyGraph.node(id: beatId)?.links.count == 1)

        // Removing a node prunes its subtree.
        m.removeNode(id: dirIds[1])
        #expect(editor.storyGraph.node(id: dirIds[1]) == nil)
        #expect(editor.storyGraph.node(id: beatId) == nil)
    }

    @Test func layoutPositionsByDepth() {
        let editor = EditorViewModel()
        let m = editor.storyGraphManager
        let rootId = m.addNode(kind: .direction, title: "root")
        let childId = m.addNode(kind: .structure, title: "child", parentId: rootId)
        let positions = m.layout(columnWidth: 260, rowHeight: 120)
        // Child sits in a deeper column (greater x) than the root.
        #expect((positions[childId]?.x ?? 0) > (positions[rootId]?.x ?? 0))
    }
}
