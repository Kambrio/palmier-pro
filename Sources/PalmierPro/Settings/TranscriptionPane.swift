import SwiftUI

struct TranscriptionPane: View {
    @State private var manager = WhisperModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            engineSection
            Divider().overlay(AppTheme.Border.subtleColor)
            modelsSection
            footer
        }
        .onAppear { manager.refreshStatesFromDisk() }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Engine")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Picker("", selection: Binding(get: { manager.engineMode }, set: { manager.engineMode = $0 })) {
                ForEach(TranscriptionEngineMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Automatic uses Apple on-device for supported languages and Whisper for the rest (e.g. Russian).")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Whisper Models")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            ForEach(WhisperModelCatalog.all) { model in
                modelRow(model)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModel) -> some View {
        let state = manager.states[model.id] ?? .notDownloaded
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(model.displayName)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    if case .downloaded = state, manager.activeModelId == model.id {
                        Text("Active")
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
                Text("\(model.approxSizeDescription) · \(model.hint)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Spacer()
            trailingControl(model, state: state)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private func trailingControl(_ model: WhisperModel, state: WhisperModelManager.ModelState) -> some View {
        switch state {
        case .notDownloaded:
            Button("Download") { manager.download(model) }
        case .downloading(let p):
            HStack(spacing: AppTheme.Spacing.xs) {
                ProgressView(value: p).frame(width: AppTheme.ComponentSize.downloadProgressWidth)
                Button("Cancel") { manager.cancelDownload(model) }
            }
        case .downloaded:
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(manager.activeModelId == model.id ? "Selected" : "Use") { manager.setActive(model) }
                    .disabled(manager.activeModelId == model.id)
                Button(role: .destructive) { manager.delete(model) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        case .error(let msg):
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(msg)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                Button("Retry") { manager.download(model) }
            }
        }
    }

    private var footer: some View {
        Text("Downloaded models use \(ByteCountFormatter.string(fromByteCount: manager.totalBytesOnDisk, countStyle: .file)) on disk.")
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.secondaryColor)
    }
}
