import AppKit
import SwiftUI

struct StoragePane: View {
    @State private var cacheBytes: Int64 = 0
    @State private var isClearing = false
    @State private var indexBytes: Int64 = 0
    @State private var modelBytes: Int64 = 0
    @State private var searchEnabled = SearchIndexConfig.enabled
    @State private var gemmaEnabled = GemmaModelManager.shared.enabled
    @State private var showGemmaRemoveConfirmation = false
    @State private var documentsOverride = DocumentPreferences.overrideDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("Cache")) {
                cacheRow
            }
            SettingsSection(title: L10n.string("Search")) {
                searchIndexSection
                Divider().overlay(AppTheme.Border.subtleColor)
                gemmaSection
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
                Text(L10n.string("Temporary files"))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(L10n.string("Playback previews, waveforms, filmstrip thumbnails, and transcripts. Safe to clear; files rebuild as needed."))
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

            Button(L10n.string("Clear cache")) {
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
                    Text(L10n.string("Media indexing"))
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(L10n.string("Indexes imported media for on-device search."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Toggle(String(), isOn: $searchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel(L10n.string("Media search"))
                    .onChange(of: searchEnabled) { _, newValue in
                        VisualModelLoader.shared.setEnabled(newValue)
                    }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Index"))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(ByteCountFormatter.string(fromByteCount: indexBytes, countStyle: .file))
                    .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer(minLength: AppTheme.Spacing.md)
                Button(L10n.string("Clear index")) { clearIndex() }
                    .buttonStyle(actionButtonStyle)
                    .disabled(indexBytes == 0)
            }
            .padding(.top, AppTheme.Spacing.xs)

            if modelBytes > 0 {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(L10n.string("Model"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(verbatim: "\(SearchIndexConfig.manifest.model) · \(ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file))")
                        .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer(minLength: AppTheme.Spacing.md)
                    Button(L10n.string("Remove model")) { removeModel() }
                        .buttonStyle(actionButtonStyle)
                }
            }
        }
    }

    private var gemmaSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string("EmbeddingGemma 2"))
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(L10n.string("Local multimodal embeddings for search, grouping, and agent tools."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Toggle(String(), isOn: $gemmaEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel(L10n.string("EmbeddingGemma 2"))
                    .onChange(of: gemmaEnabled) { _, newValue in
                        GemmaModelManager.shared.setEnabled(newValue)
                    }
            }

            if gemmaState != .unknown || GemmaModelManager.shared.enabled {
                HStack(spacing: AppTheme.Spacing.sm) {
                    gemmaStatus
                    Spacer(minLength: AppTheme.Spacing.md)
                    if gemmaAllowsRemove {
                        Button(L10n.string("Remove model")) { showGemmaRemoveConfirmation = true }
                            .buttonStyle(actionButtonStyle)
                    }
                }
                .padding(.top, AppTheme.Spacing.xs)
            }
        }
        .confirmationDialog(
            L10n.string("Remove EmbeddingGemma 2?"),
            isPresented: $showGemmaRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove model"), role: .destructive) { removeGemma() }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("This permanently deletes the downloaded model files."))
        }
    }

    private var gemmaState: GemmaModelManager.State { GemmaModelManager.shared.state }

    private var gemmaAllowsRemove: Bool {
        switch gemmaState {
        case .preparing, .ready, .failed: true
        default: false
        }
    }

    @ViewBuilder
    private var gemmaStatus: some View {
        switch gemmaState {
        case .notInstalled:
            Button(L10n.string("Install")) { GemmaModelManager.shared.download() }
                .buttonStyle(actionButtonStyle)
        case .downloading(let fraction):
            HStack(spacing: AppTheme.Spacing.xs) {
                ProgressView().controlSize(.mini)
                Text(L10n.string("Downloading \(Int(fraction * 100))%"))
                    .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        case .preparing:
            gemmaPreparingStatus
        case .ready:
            Text(L10n.string("Ready"))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(AppTheme.Background.raisedColor, in: Capsule())
        case .failed(let message):
            Button(L10n.string("Retry")) { GemmaModelManager.shared.download() }
                .buttonStyle(actionButtonStyle)
                .help(message)
        case .unknown:
            if GemmaModelManager.shared.enabled {
                gemmaPreparingStatus
            }
        }
    }

    private var gemmaPreparingStatus: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ProgressView().controlSize(.mini)
            Text(L10n.string("Preparing…"))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
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
        if isClearing { return L10n.string("Clearing…") }
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

    private func removeGemma() {
        Task { await GemmaModelManager.shared.remove() }
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
