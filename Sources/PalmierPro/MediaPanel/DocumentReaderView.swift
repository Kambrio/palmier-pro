import AppKit
import MarkdownUI
import SwiftUI

/// Identifies a document to read in-app (sheet presentation key).
struct ReaderDocument: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
    init(_ url: URL) { self.url = url }
}

/// In-app reader for documents saved by the assistant. Renders Markdown for .md files
/// and shows .srt/.vtt/.txt as monospaced text. Presented as a sheet from the editor.
struct DocumentReaderView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var loadError: String?

    private var isMarkdown: Bool { url.pathExtension.lowercased() == "md" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            ScrollView {
                Group {
                    if let loadError {
                        Text(loadError)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Status.errorColor)
                    } else if isMarkdown {
                        Markdown(content)
                            .textSelection(.enabled)
                    } else {
                        Text(content)
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(AppTheme.Spacing.lgXl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, idealWidth: 680, minHeight: 460, idealHeight: 640)
        .background(AppTheme.Background.surfaceColor)
        .task(id: url) { load() }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "doc.text")
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(url.lastPathComponent)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Open in Default App") { NSWorkspace.shared.open(url) }
                .controlSize(.small)
            Button("Done") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private func load() {
        do { content = try String(contentsOf: url, encoding: .utf8); loadError = nil }
        catch { loadError = "Couldn't open this document: \(error.localizedDescription)" }
    }
}
