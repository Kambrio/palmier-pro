import AppKit
import AVKit
import SwiftUI

/// The Shot Library: per-footage AI analysis with an editing mode for descriptions, meaningful
/// names, and editorial labels (skip / key / custom). Opened from the Documents tab.
struct ShotLibraryView: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAssetId: String?
    /// Play-vs-frames mode, held here (not in the per-asset detail editor) so switching shots keeps
    /// play mode and the next shot starts playing instead of snapping back to the frames view.
    @State private var playing = false

    private var manager: ShotLibraryManager { editor.shotLibraryManager }
    private var assets: [MediaAsset] { manager.analyzableAssets }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            if assets.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    footageList
                        .frame(width: 280)
                    Divider().overlay(AppTheme.Border.subtleColor)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 880, height: 600)
        .background(AppTheme.Background.surfaceColor)
        .onAppear { if selectedAssetId == nil { selectedAssetId = assets.first?.id } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shot Library")
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(subtitle)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            if manager.isAnalyzing {
                ProgressView().controlSize(.small)
            }
            Button(manager.library.entries.isEmpty ? "Analyze all" : "Re-analyze all") {
                manager.analyzeAll(force: !manager.library.entries.isEmpty)
            }
            .buttonStyle(.capsule(.secondary, size: .small))
            .disabled(assets.isEmpty)
            Button("Done") { dismiss() }
                .buttonStyle(.capsule(.prominent, size: .small))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private var subtitle: String {
        let analyzed = manager.library.entries.count
        let pending = manager.pendingAssetIds.count
        var s = "\(analyzed) of \(assets.count) footage analyzed"
        if pending > 0 { s += " · \(pending) pending" }
        return s
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "film.stack")
                .font(.system(size: AppTheme.FontSize.xl))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text("No video footage in this project")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Import or generate video, then analyze it to build a shot library the assistant can reason about.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footage list

    private var footageList: some View {
        ScrollView {
            LazyVStack(spacing: AppTheme.Spacing.xxs) {
                ForEach(assets) { asset in
                    footageRow(asset)
                }
            }
            .padding(AppTheme.Spacing.sm)
        }
        .background(AppTheme.Background.raisedColor)
    }

    private func footageRow(_ asset: MediaAsset) -> some View {
        let entry = manager.entry(assetId: asset.id)
        let selected = selectedAssetId == asset.id
        let progress = manager.progressByAsset[asset.id]
        return Button {
            selectedAssetId = asset.id
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                ShotThumb(relPath: entry?.frames.first(where: { $0.position == .median })?.thumbnailRelPath,
                          projectURL: editor.projectURL, maxPixel: 160)
                    .frame(width: 56, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                    .opacity(entry?.isSkipped == true ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry?.displayName ?? asset.name)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        if let entry, !entry.labels.isEmpty {
                            ForEach(entry.labels.prefix(3), id: \.self) { LabelChip(label: $0, compact: true) }
                        } else if entry == nil {
                            Text("Not analyzed")
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        } else if let size = entry?.shotSize, size != .unknown {
                            Text(size.displayName)
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let progress {
                    ProgressView(value: progress).controlSize(.small).frame(width: 28)
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(selected ? AppTheme.Background.prominentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let assetId = selectedAssetId, let asset = editor.mediaAssetsById[assetId] {
            ShotDetailEditor(asset: asset, playing: $playing)
                .id(assetId)
        } else {
            Text("Select footage")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Detail editor

private struct ShotDetailEditor: View {
    @Environment(EditorViewModel.self) private var editor
    let asset: MediaAsset
    @Binding var playing: Bool
    @State private var customLabel = ""

    private var manager: ShotLibraryManager { editor.shotLibraryManager }
    private var entry: ShotEntry? { manager.entry(assetId: asset.id) }

    /// Proxy URL when proxies are on (lighter, fast), else the source file. Nil if offline.
    private var playbackURL: URL? {
        if editor.mediaManifest.useProxies, let proxy = editor.mediaResolver.proxyURL(for: asset.id) { return proxy }
        return editor.mediaResolver.resolveURL(for: asset.id)
    }

    private var aspect: CGFloat {
        if let w = asset.sourceWidth, let h = asset.sourceHeight, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 16.0 / 9.0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if let entry {
                    mediaPreview(entry)
                    nameField(entry)
                    summaryField(entry)
                    labelsSection(entry)
                    metaSection(entry)
                    Button("Re-analyze this footage") { manager.analyze(assetId: asset.id, force: true) }
                        .buttonStyle(.capsule(.secondary, size: .small))
                } else {
                    notAnalyzed
                }
            }
            .padding(AppTheme.Spacing.lgXl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notAnalyzed: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(asset.name)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text("This footage hasn't been analyzed yet.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let p = manager.progressByAsset[asset.id] {
                ProgressView(value: p).frame(maxWidth: 240)
            } else {
                Button("Analyze footage") { manager.analyze(assetId: asset.id, force: true) }
                    .buttonStyle(.capsule(.prominent, size: .small))
            }
        }
    }

    /// The sampled frames, with a toggle to play the footage inline (proxy/source) instead.
    @ViewBuilder
    private func mediaPreview(_ entry: ShotEntry) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                fieldLabel(playing ? "Playing footage" : "Frames")
                Spacer()
                if playbackURL != nil {
                    Button {
                        playing.toggle()
                    } label: {
                        Label(playing ? "Show frames" : "Play footage",
                              systemImage: playing ? "rectangle.split.3x1" : "play.fill")
                    }
                    .buttonStyle(.capsule(.secondary, size: .small))
                    .help(editor.mediaManifest.useProxies ? "Play the proxy (fast)" : "Play the source footage")
                }
            }
            if playing, let url = playbackURL {
                ShotPlayer(url: url)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            } else {
                framesStrip(entry)
            }
        }
    }

    private func framesStrip(_ entry: ShotEntry) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            ForEach(ShotPosition.allCases, id: \.self) { pos in
                let frame = entry.frames.first { $0.position == pos }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    ShotThumb(relPath: frame?.thumbnailRelPath, projectURL: editor.projectURL, maxPixel: 640)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    Text(pos.label)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    if let frame, let desc = frame.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    private func nameField(_ entry: ShotEntry) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            fieldLabel("Name (shown on the timeline)")
            TextField("Meaningful name", text: Binding(
                get: { entry.displayName ?? "" },
                set: { manager.setDisplayName(assetId: asset.id, $0) }))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: AppTheme.FontSize.sm))
        }
    }

    private func summaryField(_ entry: ShotEntry) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            fieldLabel("Description")
            TextEditor(text: Binding(
                get: { entry.summary },
                set: { manager.setSummary(assetId: asset.id, $0) }))
            .font(.system(size: AppTheme.FontSize.sm))
            .frame(minHeight: 70)
            .padding(AppTheme.Spacing.xxs)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
        }
    }

    private func labelsSection(_ entry: ShotEntry) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            fieldLabel("Labels")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: AppTheme.Spacing.xxs)], alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                ForEach(ShotLabels.all) { def in
                    let active = entry.labels.contains(def.id)
                    let color = LabelPalette.color(def.id)
                    Button { manager.toggleLabel(assetId: asset.id, def.id) } label: {
                        HStack(spacing: AppTheme.Spacing.xxs) {
                            Image(systemName: def.systemImage).font(.system(size: AppTheme.FontSize.xxs))
                            Text(def.title).font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        }
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(active ? color.opacity(AppTheme.Opacity.faint) : AppTheme.Background.raisedColor))
                        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(active ? color.opacity(AppTheme.Opacity.strong) : AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
                        .foregroundStyle(active ? color : AppTheme.Text.secondaryColor)
                        .help(def.hint)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Custom labels already attached but not predefined.
            let custom = entry.labels.filter { id in !ShotLabels.all.contains { $0.id == id } }
            if !custom.isEmpty {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    ForEach(custom, id: \.self) { label in
                        HStack(spacing: 2) {
                            LabelChip(label: label, compact: false)
                            Button { manager.toggleLabel(assetId: asset.id, label) } label: {
                                Image(systemName: "xmark").font(.system(size: AppTheme.FontSize.xxs))
                            }.buttonStyle(.plain).foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                    }
                }
            }
            HStack(spacing: AppTheme.Spacing.xs) {
                TextField("Custom label", text: $customLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .frame(maxWidth: 160)
                    .onSubmit(addCustom)
                Button("Add", action: addCustom)
                    .buttonStyle(.capsule(.secondary, size: .small))
                    .disabled(customLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addCustom() {
        let label = ShotLabels.normalize(customLabel)
        guard !label.isEmpty else { return }
        if entry?.labels.contains(label) != true { manager.toggleLabel(assetId: asset.id, label) }
        customLabel = ""
    }

    private func metaSection(_ entry: ShotEntry) -> some View {
        let bits: [String] = [
            entry.shotSize.flatMap { $0 == .unknown ? nil : "Shot: \($0.displayName)" },
            entry.people.map { "People: \($0)" },
            entry.personGroup.map { "Person group #\($0 + 1)" },
            entry.hasSpeech == true ? "Has speech" : nil,
            entry.durationSeconds.map { String(format: "%.1fs", $0) },
        ].compactMap { $0 }
        return Text(bits.joined(separator: "  ·  "))
            .font(.system(size: AppTheme.FontSize.xxs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
    }
}

// MARK: - Small components

/// Resolves a label id to its color-coding hue: the catalog token for built-ins, or a stable
/// hash into the palette for custom labels.
enum LabelPalette {
    private static let customHues: [Color] = [
        AppTheme.Label.blue, AppTheme.Label.teal, AppTheme.Label.green,
        AppTheme.Label.pink, AppTheme.Label.purple, AppTheme.Label.orange,
    ]

    static func color(_ id: String) -> Color {
        if let token = ShotLabels.def(id)?.colorToken { return color(token: token) }
        // Stable, deterministic hue per custom label string.
        let hash = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return customHues[hash % customHues.count]
    }

    static func color(token: String) -> Color {
        switch token {
        case "amber":  AppTheme.Label.amber
        case "red":    AppTheme.Label.red
        case "orange": AppTheme.Label.orange
        case "blue":   AppTheme.Label.blue
        case "teal":   AppTheme.Label.teal
        case "green":  AppTheme.Label.green
        case "pink":   AppTheme.Label.pink
        case "purple": AppTheme.Label.purple
        default:       AppTheme.Label.neutral
        }
    }
}

private struct LabelChip: View {
    let label: String
    let compact: Bool
    var body: some View {
        let def = ShotLabels.def(label)
        let color = LabelPalette.color(label)
        return HStack(spacing: 2) {
            if let def { Image(systemName: def.systemImage).font(.system(size: AppTheme.FontSize.xxs)) }
            Text(def?.title ?? label)
                .font(.system(size: compact ? AppTheme.FontSize.xxs : AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(AppTheme.Opacity.faint)))
        .overlay(Capsule().strokeBorder(color.opacity(AppTheme.Opacity.medium), lineWidth: AppTheme.BorderWidth.hairline))
        .foregroundStyle(color)
    }
}

/// Small in-memory cache of decoded shot thumbnails, keyed by package-relative path + decode size.
@MainActor private let shotThumbCache = NSCache<NSString, NSImage>()

private struct ShotThumb: View {
    let relPath: String?
    let projectURL: URL?
    /// Long-edge decode size in pixels, sized to the display: small for list rows, larger for the
    /// retina detail frames. The stored JPEG is ~768px, so anything up to that decodes crisply.
    var maxPixel: Int = 320
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(AppTheme.Background.prominentColor)
                    .overlay(Image(systemName: "film").font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(AppTheme.Text.tertiaryColor))
            }
        }
        .clipped()
        .task(id: relPath.map { "\($0)#\(maxPixel)" }) { await load() }
    }

    private func load() async {
        guard let relPath, let projectURL else { image = nil; return }
        let key = "\(relPath)#\(maxPixel)" as NSString
        if let cached = shotThumbCache.object(forKey: key) { image = cached; return }
        let px = maxPixel
        let cg = await Task.detached(priority: .utility) {
            ShotThumbnailStore.loadDownsampled(relativePath: relPath, projectURL: projectURL, maxPixel: px)
        }.value
        guard let cg else { return }
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        shotThumbCache.setObject(nsImage, forKey: key)
        image = nsImage
    }
}

/// A lightweight single-file player for the Shot Library — native AVKit transport controls (scrub,
/// play/pause, volume, fullscreen). Standalone (no VideoEngine/timeline coupling); pauses and releases
/// its player when the view goes away so it never leaks or keeps playing off-screen.
private struct ShotPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        let player = AVPlayer(url: url)
        view.player = player
        player.play()   // auto-play once the player is shown
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let current = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        guard current != url else { return }
        view.player?.pause()
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
