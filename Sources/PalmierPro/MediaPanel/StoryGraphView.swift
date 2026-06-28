import AppKit
import SwiftUI

/// The Story Graph: an interactive tree for developing a video's story from real footage. The root
/// is the project's direction/genre; branches are structures → acts → beats; beats link to footage,
/// captions, and documents. Users click nodes to branch and link; the AI assistant does the same via
/// the story MCP tools. Opened from the Documents tab.
struct StoryGraphView: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var selectedId: String?
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var previewToast: String?

    /// Committed zoom × the live pinch delta, clamped. Avoids any stale-anchor desync between the
    /// zoom buttons and the pinch gesture.
    private var effectiveScale: CGFloat { min(Self.maxScale, max(Self.minScale, scale * pinch)) }

    private var manager: StoryGraphManager { editor.storyGraphManager }
    private var graph: StoryGraph { editor.storyGraph }

    private static let nodeWidth: CGFloat = 200
    private static let pad: CGFloat = 80
    private static let minScale: CGFloat = 0.4
    private static let maxScale: CGFloat = 2.0

    /// Footage-grounded prompt the assistant uses to recommend top-level story directions.
    static let directionRecommendationPrompt = """
        Help me develop a story for this project. First look at my footage — call get_shot_library \
        (and analyze_footage if anything is unanalyzed) — then recommend 2–4 story directions that best \
        suit what I actually have. Add them to the story graph with add_story_nodes (no parentId) and \
        briefly say why each fits the footage.
        """

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            HStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Only show the inspector while the selected node still exists (the agent/UI may
                // delete it out-of-band) — otherwise the 300pt panel would render blank.
                if let id = selectedId, graph.node(id: id) != nil {
                    Divider().overlay(AppTheme.Border.subtleColor)
                    inspector.frame(width: 300)
                }
            }
        }
        .frame(width: 980, height: 640)
        .background(AppTheme.Background.surfaceColor)
        .overlay(alignment: .bottom) {
            if let message = previewToast {
                Text(message)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .background(Capsule().fill(AppTheme.Background.prominentColor))
                    .overlay(Capsule().strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
                    .padding(.bottom, AppTheme.Spacing.lg)
                    .transition(.opacity)
                    .task(id: previewToast) {
                        try? await Task.sleep(for: .seconds(3))
                        previewToast = nil
                    }
            }
        }
        .animation(.easeInOut(duration: AppTheme.Anim.transition), value: previewToast)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Story Graph")
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(subtitle)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            if graph.isEmpty {
                Button {
                    editor.handToAssistant(prompt: Self.directionRecommendationPrompt)
                } label: {
                    Label("Recommend directions", systemImage: "sparkles")
                }
                .buttonStyle(.capsule(.secondary, size: .small))
                .help("Ask the assistant to suggest story directions that fit your footage")
                Button("Start with directions") { _ = manager.addSuggestedChildren(parentId: nil) }
                    .buttonStyle(.capsule(.prominent, size: .small))
            } else {
                zoomControls
                previewControls
                Button("Clear", role: .destructive) { manager.clear(); selectedId = nil; manager.clearTimelinePreview() }
                    .buttonStyle(.capsule(.secondary, size: .small))
            }
            Button("Done") { dismiss() }
                .buttonStyle(.capsule(.prominent, size: .small))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private var subtitle: String {
        if graph.isEmpty { return "Branch from a direction into beats, then link footage" }
        let chosen = graph.nodes.filter(\.chosen).count
        return "\(graph.nodes.count) nodes · \(chosen) chosen · drag to scroll, pinch to zoom"
    }

    private var zoomControls: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Button { setScale(scale - 0.2) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.capsule(.secondary, size: .small)).help("Zoom out")
            Text("\(Int(effectiveScale * 100))%")
                .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 40)
            Button { setScale(scale + 0.2) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.capsule(.secondary, size: .small)).help("Zoom in")
            Button { withAnimation { setScale(1) } } label: { Image(systemName: "1.square") }
                .buttonStyle(.capsule(.secondary, size: .small)).help("Actual size")
        }
    }

    private func setScale(_ v: CGFloat) { scale = min(Self.maxScale, max(Self.minScale, v)) }

    private var previewControls: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Button {
                let result = manager.buildTimelinePreview()
                if result.placed > 0 {
                    dismiss()   // reveal the timeline so the bands are visible
                } else {
                    previewToast = "Link footage to your beats and place it on the timeline to preview it here."
                }
            } label: {
                Label("Preview on timeline", systemImage: "rectangle.split.3x1")
            }
            .buttonStyle(.capsule(.secondary, size: .small))
            .help("Highlight the timeline sections your beats' footage occupies")
            if manager.hasTimelinePreview {
                Button { manager.clearTimelinePreview() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.capsule(.secondary, size: .small))
                    .help("Clear the timeline preview")
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let positions = manager.layout(columnWidth: 260, rowHeight: 120)
            let contentW = max((positions.values.map(\.x).max() ?? 0) + Self.nodeWidth + Self.pad, 600)
            let contentH = max((positions.values.map(\.y).max() ?? 0) + Self.pad * 2, 400)
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    edgeCanvas(positions: positions)
                    ForEach(graph.nodes) { node in
                        nodeCard(node)
                            .position(displayPoint(node, positions: positions))
                    }
                }
                .frame(width: contentW, height: contentH)
                .scaleEffect(effectiveScale, anchor: .topLeading)
                .frame(width: contentW * effectiveScale, height: contentH * effectiveScale, alignment: .topLeading)
                .padding(Self.pad)
            }
            .scrollPosition($scrollPosition)
            .background(AppTheme.Background.baseColor)
            .gesture(
                MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in setScale(scale * value) }
            )
            .overlay(alignment: .bottomLeading) { if graph.isEmpty { emptyHint } }
            .onChange(of: manager.focusRequest?.token) { _, _ in
                if let id = manager.focusRequest?.id { focusCamera(on: id, viewport: geo.size) }
            }
        }
    }

    /// Move the scroll "camera" so `nodeId` is centered in the viewport (animated).
    private func focusCamera(on nodeId: String, viewport: CGSize) {
        let positions = manager.layout(columnWidth: 260, rowHeight: 120)
        guard let base = positions[nodeId], viewport.width > 0 else { return }
        let centerX = Self.pad + (base.x + Self.nodeWidth / 2 + 20) * effectiveScale
        let centerY = Self.pad + (base.y + 20) * effectiveScale
        let target = CGPoint(x: max(0, centerX - viewport.width / 2),
                             y: max(0, centerY - viewport.height / 2))
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            scrollPosition.scrollTo(point: target)
        }
    }

    private func edgeCanvas(positions: [String: CGPoint]) -> some View {
        Canvas { ctx, _ in
            for node in graph.nodes {
                // Use the positions dict directly (O(1)) instead of graph.node(id:) — the latter is a
                // linear scan, which made this O(N²) and ran on every scroll-driven body re-eval.
                guard let parentId = node.parentId,
                      let parentBase = positions[parentId],
                      let nodeBase = positions[node.id] else { continue }
                let from = displayPoint(base: parentBase)
                let to = displayPoint(base: nodeBase)
                var path = Path()
                path.move(to: CGPoint(x: from.x + Self.nodeWidth / 2, y: from.y))
                let midX = (from.x + to.x) / 2 + Self.nodeWidth / 2
                path.addCurve(
                    to: CGPoint(x: to.x - Self.nodeWidth / 2, y: to.y),
                    control1: CGPoint(x: midX, y: from.y),
                    control2: CGPoint(x: midX, y: to.y))
                ctx.stroke(path, with: .color(node.chosen ? AppTheme.Accent.timecodeColor : AppTheme.Border.primaryColor),
                           lineWidth: node.chosen ? 2 : 1)
            }
        }
    }

    private func displayPoint(_ node: StoryNode, positions: [String: CGPoint]) -> CGPoint {
        displayPoint(base: positions[node.id] ?? .zero)
    }

    /// Card-center point for a node's layout base (top-left), applying the card offset.
    private func displayPoint(base: CGPoint) -> CGPoint {
        CGPoint(x: base.x + Self.nodeWidth / 2 + 20, y: base.y + 20)
    }

    private var emptyHint: some View {
        Text("Click “Start with directions”, or ask the assistant to develop a story from your footage.")
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .padding(AppTheme.Spacing.md)
    }

    // MARK: - Node card

    private func nodeCard(_ node: StoryNode) -> some View {
        let selected = selectedId == node.id
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Text(node.kind.displayName.uppercased())
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                    .foregroundStyle(kindColor(node.kind))
                Spacer(minLength: 0)
                if node.chosen { Image(systemName: "checkmark.seal.fill").font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Accent.timecodeColor) }
                if node.createdByAI { Image(systemName: "sparkles").font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Text.tertiaryColor) }
            }
            Text(node.title)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(2)
            if !node.summary.isEmpty {
                Text(node.summary)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(2)
            }
            if !node.links.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "link").font(.system(size: AppTheme.FontSize.xxs))
                    Text("\(node.links.count)").font(.system(size: AppTheme.FontSize.xxs))
                }.foregroundStyle(AppTheme.Accent.timecodeColor)
            }
        }
        .padding(AppTheme.Spacing.sm)
        .frame(width: Self.nodeWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.md).fill(AppTheme.Background.raisedColor))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.md)
            .strokeBorder(selected ? AppTheme.Accent.timecodeColor : kindColor(node.kind).opacity(AppTheme.Opacity.medium),
                          lineWidth: selected ? 2 : 1))
        .shadow(AppTheme.Shadow.sm)
        .onTapGesture { selectedId = node.id }
    }

    private func kindColor(_ kind: StoryNodeKind) -> Color {
        switch kind {
        case .direction: AppTheme.Label.amber
        case .structure: AppTheme.Label.blue
        case .act:       AppTheme.Label.purple
        case .beat:      AppTheme.Label.teal
        case .block:     AppTheme.Label.neutral
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let id = selectedId, let node = graph.node(id: id) {
            StoryNodeInspector(node: node, onDeselect: { selectedId = nil })
                .id(id)
        }
    }
}

// MARK: - Node inspector

private struct StoryNodeInspector: View {
    @Environment(EditorViewModel.self) private var editor
    let node: StoryNode
    let onDeselect: () -> Void
    @State private var showLinkPicker = false

    private var manager: StoryGraphManager { editor.storyGraphManager }
    private var live: StoryNode { editor.storyGraph.node(id: node.id) ?? node }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Text(live.kind.displayName)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer()
                    Toggle("Chosen", isOn: Binding(
                        get: { live.chosen },
                        set: { manager.setChosen(id: node.id, $0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: AppTheme.FontSize.xs))
                }

                field("Title") {
                    TextField("Title", text: Binding(
                        get: { live.title },
                        set: { manager.updateNode(id: node.id, title: $0) }))
                    .textFieldStyle(.roundedBorder)
                }
                field("Summary") {
                    TextEditor(text: Binding(
                        get: { live.summary },
                        set: { manager.updateNode(id: node.id, summary: $0) }))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .frame(minHeight: 60)
                    .padding(AppTheme.Spacing.xxs)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
                }

                Button {
                    editor.handToAssistant(prompt: recommendationPrompt(for: live))
                } label: {
                    Label("Recommend with AI", systemImage: "sparkles")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.prominent, size: .small))
                .help("Open the chat with this node's context so the assistant can recommend what best suits your footage")

                branchSection
                linksSection

                Button("Delete node", role: .destructive) {
                    manager.removeNode(id: node.id); onDeselect()
                }
                .buttonStyle(.capsule(.secondary, size: .small))
            }
            .padding(AppTheme.Spacing.lgXl)
        }
    }

    private var branchSection: some View {
        let suggestion = StoryTemplates.childSuggestions(forParent: live)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            fieldLabel("Add \(suggestion.kind.displayName.lowercased()) options")
            ForEach(suggestion.templates, id: \.title) { t in
                Button {
                    manager.addNode(kind: suggestion.kind, title: t.title, summary: t.summary, parentId: node.id)
                } label: {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
                        Image(systemName: t.recommended ? "star.fill" : "plus.circle")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(t.recommended ? AppTheme.Label.amber : AppTheme.Text.tertiaryColor)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: AppTheme.Spacing.xxs) {
                                Text(t.title).font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                                if t.recommended {
                                    Text("Recommended")
                                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                                        .foregroundStyle(AppTheme.Label.amber)
                                        .padding(.horizontal, AppTheme.Spacing.xxs)
                                        .background(Capsule().fill(AppTheme.Label.amber.opacity(AppTheme.Opacity.faint)))
                                }
                            }
                            Text(t.summary).font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Text.tertiaryColor).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AppTheme.Spacing.sm).padding(.vertical, AppTheme.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(t.recommended ? AppTheme.Label.amber.opacity(AppTheme.Opacity.medium) : Color.clear, lineWidth: AppTheme.BorderWidth.thin))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                fieldLabel("Linked footage & elements")
                Spacer()
                Button { showLinkPicker.toggle() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(AppTheme.Accent.timecodeColor)
                    .help("Link footage")
            }
            if live.links.isEmpty {
                Text("Link the footage that fills this beat.")
                    .font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            ForEach(live.links) { link in
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Image(systemName: linkIcon(link.kind)).font(.system(size: AppTheme.FontSize.xxs))
                    Text(manager.label(for: link)).font(.system(size: AppTheme.FontSize.xs)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { manager.removeLink(id: node.id, linkId: link.id) } label: { Image(systemName: "xmark").font(.system(size: AppTheme.FontSize.xxs)) }
                        .buttonStyle(.plain).foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if showLinkPicker { footagePicker }
        }
    }

    private var footagePicker: some View {
        let videos = editor.mediaAssets.filter { $0.type == .video }
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ForEach(videos) { asset in
                let name = editor.shotLibrary.entry(assetId: asset.id)?.displayName ?? asset.name
                Button {
                    manager.addLink(id: node.id, kind: .footage, ref: asset.id, label: name)
                    showLinkPicker = false
                } label: {
                    HStack { Image(systemName: "film").font(.system(size: AppTheme.FontSize.xxs)); Text(name).font(.system(size: AppTheme.FontSize.xs)).lineLimit(1); Spacer(minLength: 0) }
                        .padding(.horizontal, AppTheme.Spacing.xs).padding(.vertical, 2)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .buttonStyle(.plain)
            }
            if videos.isEmpty {
                Text("No video footage in this project.").font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .padding(AppTheme.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.baseColor))
    }

    private func linkIcon(_ kind: StoryLink.Kind) -> String {
        switch kind {
        case .footage: "film"
        case .clip:    "rectangle.on.rectangle"
        case .caption: "captions.bubble"
        case .document: "doc.text"
        }
    }

    /// A footage-grounded prompt seeding the chat to recommend the next move for this node.
    private func recommendationPrompt(for node: StoryNode) -> String {
        let intro = "I'm developing my video's story on the story graph. Look at my footage first — call get_shot_library (and analyze_footage if anything is unanalyzed) — and recommend what best suits it."
        var context = "Current node — \(node.kind.displayName): “\(node.title)”"
        if !node.summary.isEmpty { context += " (\(node.summary))" }
        context += ". Its node id is \(node.id)."
        if !node.links.isEmpty {
            context += " Already linked footage: " + node.links.map { manager.label(for: $0) }.joined(separator: ", ") + "."
        }
        let ask: String
        switch node.kind {
        case .direction:
            ask = "Tell me whether this direction fits my footage, then add 2–3 story structure options under it with add_story_nodes (parentId \(node.id))."
        case .structure:
            ask = "Add the best beats for this structure under it with add_story_nodes (parentId \(node.id)), each grounded in specific footage."
        case .act:
            ask = "Add the beats for this act under it with add_story_nodes (parentId \(node.id))."
        case .beat:
            ask = "Recommend which of my footage should fill this beat and link it with set_story_node (nodeId \(node.id), addLinks). Add useful building blocks too."
        case .block:
            ask = "Recommend the specific footage for this block and link it with set_story_node (nodeId \(node.id), addLinks)."
        }
        return [intro, context, ask].joined(separator: "\n\n")
    }

    private func field<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) { fieldLabel(label); content() }
    }
    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium)).foregroundStyle(AppTheme.Text.secondaryColor)
    }
}
