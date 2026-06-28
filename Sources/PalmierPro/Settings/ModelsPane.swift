import SwiftUI

struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared
    private var higgsfield = HiggsfieldCatalog.shared
    private var runtime = OmniVoiceRuntime.shared

    @State private var query = ""
    @State private var provider: GenerationProvider = GenerationProvider.selected
    @State private var higgsfieldLoggedIn = false

    private struct Row: Identifiable {
        let id: String
        let displayName: String
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func filtered(_ rows: [Row]) -> [Row] {
            q.isEmpty ? rows : rows.filter { $0.displayName.lowercased().contains(q) }
        }
        return [
            Section(id: "image", title: "Image",
                    rows: filtered(catalog.image.map { Row(id: $0.id, displayName: $0.displayName) })),
            Section(id: "video", title: "Video",
                    rows: filtered(catalog.video.map { Row(id: $0.id, displayName: $0.displayName) })),
            Section(id: "audio", title: "Audio",
                    rows: filtered(catalog.audio.map { Row(id: $0.id, displayName: $0.displayName) })),
        ].filter { !$0.rows.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            providerSection
            Divider().overlay(AppTheme.Border.subtleColor)
            if provider == .palmier {
                palmierContent
            } else if provider == .higgsfield {
                higgsfieldContent
            } else {
                omniVoiceContent
            }
        }
        .task(id: provider) { if provider == .higgsfield { await refreshHiggsfield() } }
    }

    @ViewBuilder
    private var palmierContent: some View {
        searchBar
        if sections.isEmpty {
            Text(catalog.isLoaded ? "No models match \"\(query)\"." : "Loading models…")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .padding(.top, AppTheme.Spacing.lg)
        } else {
            ForEach(sections) { section in
                sectionView(section)
            }
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Generation Provider")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Picker("", selection: $provider) {
                ForEach(GenerationProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: provider) { _, newValue in GenerationProvider.selected = newValue }

            if provider == .higgsfield { higgsfieldStatusRow }
        }
    }

    private var higgsfieldStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            if HiggsfieldCLI.isAvailable && !higgsfieldLoggedIn {
                Button("Log in") { Task { try? await HiggsfieldCLI.login(); await refreshHiggsfield() } }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(AppTheme.Opacity.muted)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
    }

    @ViewBuilder
    private var higgsfieldContent: some View {
        if !HiggsfieldCLI.isAvailable {
            Text("Install the higgsfield CLI to use this provider.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        } else if !higgsfieldLoggedIn {
            Text("Log in to Higgsfield to load available models.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        } else {
            higgsfieldGroup("IMAGE", higgsfield.image)
            higgsfieldGroup("VIDEO", higgsfield.video)
        }
    }

    @ViewBuilder
    private func higgsfieldGroup(_ title: String, _ models: [HiggsfieldModel]) -> some View {
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, m in
                        HStack {
                            Text(m.displayName)
                                .font(.system(size: AppTheme.FontSize.md))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            Spacer()
                        }
                        .padding(.vertical, AppTheme.Spacing.smMd)
                        if index < models.count - 1 {
                            Divider().overlay(AppTheme.Border.subtleColor)
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle)))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin))
            }
        }
    }

    @ViewBuilder
    private var omniVoiceContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle().fill(omniStatusColor).frame(width: 8, height: 8)
                Text(omniStatusText)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                omniActionButton
            }
            if case .provisioning(let value, let label) = runtime.state {
                ProgressView(value: value) {
                    Text(label).font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            Text("On-device text-to-speech (646 languages, voice cloning). Runs locally — no sign-in, no credits. First install downloads ~3.5 GB.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(AppTheme.Opacity.muted)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
        .task { runtime.refresh() }
    }

    @ViewBuilder
    private var omniActionButton: some View {
        switch runtime.state {
        case .ready:
            EmptyView()
        case .provisioning:
            Button("Installing…") {}.disabled(true)
                .buttonStyle(.capsule(.secondary, size: .regular)).controlSize(.small)
        default:
            Button("Install runtime") { Task { try? await runtime.provision() } }
                .buttonStyle(.capsule(.secondary, size: .regular)).controlSize(.small)
        }
    }

    private var omniStatusColor: Color {
        switch runtime.state {
        case .ready: return .green
        case .provisioning: return .orange
        case .error: return .red
        default: return AppTheme.Text.mutedColor
        }
    }

    private var omniStatusText: String {
        switch runtime.state {
        case .ready: return "OmniVoice runtime ready"
        case .provisioning: return "Installing runtime…"
        case .error(let m): return "Error: \(m)"
        case .notInstalled: return "Runtime not installed"
        case .unknown: return "Checking…"
        }
    }

    private var statusColor: Color {
        if !HiggsfieldCLI.isAvailable { return AppTheme.Text.mutedColor }
        return higgsfieldLoggedIn ? .green : .orange
    }

    private var statusText: String {
        if !HiggsfieldCLI.isAvailable { return "higgsfield not found on PATH" }
        return higgsfieldLoggedIn ? "Logged in to Higgsfield" : "Not logged in"
    }

    private func refreshHiggsfield() async {
        higgsfieldLoggedIn = await HiggsfieldCLI.isLoggedIn()
        if higgsfieldLoggedIn { await higgsfield.refresh() }
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(section.title.uppercased())
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .tracking(AppTheme.Tracking.tight)
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    modelRow(row)
                    if index < section.rows.count - 1 {
                        Divider().overlay(AppTheme.Border.subtleColor)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
            )
        }
    }

    private func modelRow(_ row: Row) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(row.displayName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.lg)
            Toggle("", isOn: Binding(
                get: { prefs.isEnabled(row.id) },
                set: { prefs.setEnabled(row.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }
}
