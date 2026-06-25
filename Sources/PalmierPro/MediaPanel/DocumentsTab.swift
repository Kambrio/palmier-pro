import AppKit
import SwiftUI

/// Library tab listing the documents the assistant saved (scripts, hooks, notes,
/// transcript/caption exports) in the project's documents folder. Open, reveal, or delete them.
struct DocumentsTab: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var files: [URL] = []

    private var directory: URL { DocumentsStore.baseDirectory(projectURL: editor.projectURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            if files.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.xxs) {
                        ForEach(files, id: \.self) { row($0) }
                    }
                    .padding(AppTheme.Spacing.sm)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.surfaceColor)
        .task(id: editor.projectURL) { reload() }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Documents")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer()
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).focusable(false)
                .help("Refresh")
            Button { NSWorkspace.shared.open(ensuredDirectory()) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).focusable(false)
                .help("Open documents folder in Finder")
        }
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "doc.text")
                .font(.system(size: AppTheme.FontSize.xl))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text("No documents yet")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Ask the assistant to save a script, hooks, or export captions, and they'll appear here.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppTheme.Spacing.lgXl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon(for: url))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.sm)
            Text(url.lastPathComponent)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, AppTheme.Spacing.xs)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm, isActive: false)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Move to Trash", role: .destructive) {
                NSWorkspace.shared.recycle([url]) { _, _ in Task { @MainActor in reload() } }
            }
        }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "srt", "vtt": "captions.bubble"
        case "md": "doc.richtext"
        default: "doc.text"
        }
    }

    @discardableResult
    private func ensuredDirectory() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        files = urls
            .filter { DocumentsStore.allowedFormats.contains($0.pathExtension.lowercased()) }
            .sorted { modified($0) > modified($1) }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
