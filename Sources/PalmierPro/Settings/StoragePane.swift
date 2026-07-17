import AppKit
import SwiftUI

struct StoragePane: View {
    @State private var cacheBytes: Int64 = 0
    @State private var isClearing = false
    @State private var indexBytes: Int64 = 0
    @State private var modelBytes: Int64 = 0
    @State private var searchEnabled = SearchIndexConfig.enabled
    @State private var documentsOverride = DocumentPreferences.overrideDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: "Cache") {
                cacheRow
            }
            SettingsSection(title: "Search") {
                searchIndexSection
            }
            SettingsSection(title: "Documents") {
                documentsSection
            }
        }
        .task { await refresh() }
    }

    private var cacheRow: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Temporary files")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Playback previews, waveforms, filmstrip thumbnails, and transcripts. Safe to clear; files rebuild as needed.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(displayPath)
                        .font(.system(size: AppTheme.FontSize.xs).monospaced())
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(formattedSize)
                        .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .padding(.top, AppTheme.Spacing.xs)
            }

            Spacer(minLength: AppTheme.Spacing.lg)

            Button("Clear cache") {
                clear()
            }
            .buttonStyle(actionButtonStyle)
            .disabled(isClearing || cacheBytes == 0)
        }
    }

    private var documentsSection: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Documents")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Where the assistant saves scripts, hooks, notes, and transcript or caption exports.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(documentsOverride?.path ?? "Inside each project (.palmier/documents)")
                    .font(.system(size: AppTheme.FontSize.xs).monospaced())
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, AppTheme.Spacing.xs)
            }

            Spacer(minLength: AppTheme.Spacing.lg)

            VStack(spacing: AppTheme.Spacing.xs) {
                Button("Change…") { chooseDocumentsFolder() }
                    .controlSize(.small)
                if documentsOverride != nil {
                    Button("Use default") {
                        DocumentPreferences.overrideDirectory = nil
                        documentsOverride = nil
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func chooseDocumentsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for assistant-saved documents"
        if panel.runModal() == .OK, let url = panel.url {
            DocumentPreferences.overrideDirectory = url
            documentsOverride = url
        }
    }

    private var searchIndexSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Media indexing")
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Indexes imported media for on-device search.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Toggle("", isOn: $searchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Media search")
                    .onChange(of: searchEnabled) { _, newValue in
                        VisualModelLoader.shared.setEnabled(newValue)
                    }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Index")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(ByteCountFormatter.string(fromByteCount: indexBytes, countStyle: .file))
                    .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer(minLength: AppTheme.Spacing.md)
                Button("Clear index") { clearIndex() }
                    .buttonStyle(actionButtonStyle)
                    .disabled(indexBytes == 0)
            }
            .padding(.top, AppTheme.Spacing.xs)

            if modelBytes > 0 {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("Model")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text("\(SearchIndexConfig.manifest.model) · \(ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file))")
                        .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer(minLength: AppTheme.Spacing.md)
                    Button("Remove model") { removeModel() }
                        .buttonStyle(actionButtonStyle)
                }
            }
        }
    }

    private var actionButtonStyle: CapsuleButtonStyle {
        .init(
            variant: .secondary,
            size: .small,
            fill: AnyShapeStyle(AppTheme.Background.raisedColor)
        )
    }

    private nonisolated static let caches = [ImageVideoGenerator.cache, MediaVisualCache.diskCache, DiskCache(directory: TranscriptCache.directory), AudioEnhancer.cache, VoiceActivity.cache, SpeakerIdentity.cache]

    private var displayPath: String {
        DiskCache.rootDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var formattedSize: String {
        if isClearing { return "Clearing…" }
        return ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private func clear() {
        isClearing = true
        Task.detached {
            for cache in Self.caches { cache.clear() }
            await TranscriptCache.shared.clearMemory()
            await MainActor.run {
                isClearing = false
                for document in NSDocumentController.shared.documents {
                    (document as? VideoProject)?.editorViewModel.resetAnalysisSessionState()
                }
            }
            await refresh()
        }
    }

    private func clearIndex() {
        Task {
            await SearchIndexCoordinator.clearIndexGlobally()
            await refresh()
        }
    }

    private func removeModel() {
        Task {
            await VisualModelLoader.shared.remove()
            await refresh()
        }
    }

    private func refresh() async {
        let sizes = await Task.detached {
            (
                cache: Self.caches.reduce(0) { $0 + $1.size() },
                index: DiskCache.bytes(at: EmbeddingStore.directory),
                model: DiskCache.bytes(at: ModelDownloader.modelsDir)
            )
        }.value
        cacheBytes = sizes.cache
        indexBytes = sizes.index
        modelBytes = sizes.model
    }
}
