import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var anthropicHasKey: Bool = false
    @State private var anthropicMasked: String = ""
    @State private var anthropicDraft: String = ""
    @State private var zaiHasKey: Bool = false
    @State private var zaiMasked: String = ""
    @State private var zaiDraft: String = ""
    @State private var backend: ChatBackend = ChatBackend.selected
    @State private var claudeFound: Bool = false
    @State private var cliModel: AnthropicModel = ClaudeCLIModelPreference.value
    @State private var zaiModel: ZaiModel = ZaiModelPreference.value

    private let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")!
    private let zaiSubscribeURL = URL(string: "https://z.ai/subscribe")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            backendSection
            if showsKeySection {
                Divider().overlay(AppTheme.Border.subtleColor)
                keySection
            }
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
            if showsSkillsSection {
                Divider().overlay(AppTheme.Border.subtleColor)
                skillsSection
            }
            Divider().overlay(AppTheme.Border.subtleColor)
            transcriptSection
        }
        .onAppear(perform: refresh)
    }

    private var showsKeySection: Bool {
        backend == .apiKey || backend == .zai
    }

    /// Skills global-install only matters for the Claude Code CLI path (terminal `claude`
    /// discovers skills from ~/.claude/skills). The in-app API/z.ai agent gets skills via the
    /// system-prompt index, so the toggle is irrelevant there — hide it unless the CLI is in use
    /// or installed on PATH.
    private var showsSkillsSection: Bool {
        backend == .claudeCLI || claudeFound
    }

    @ViewBuilder
    private var keySection: some View {
        switch backend {
        case .apiKey: apiKeySection
        case .zai: zaiKeySection
        default: EmptyView()
        }
    }

    @State private var transcriptDetail = ChatTranscriptDetail.selected

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Chat history")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text("How much tool-result detail to save in this project's chat history. Affects only stored and displayed history — never what's sent to the model or your token cost.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.sm) {
                Picker("", selection: $transcriptDetail) {
                    ForEach(ChatTranscriptDetail.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: transcriptDetail) { _, v in ChatTranscriptDetail.selected = v }
                Spacer()
            }
            Text(transcriptDetail.detail)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    @State private var installSkillsGlobally = ClaudeCLISkills.globalInstallEnabled

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Skills")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text("Palmier bundles creative skills (montage-editing, story-development, scriptwriter, and more) for the in-app chat. Turn this on to also install them into your global Claude CLI (~/.claude/skills) so your own terminal sessions can use them.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Install skills for your Claude CLI")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                Toggle("", isOn: $installSkillsGlobally)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .onChange(of: installSkillsGlobally) { _, on in
                        ClaudeCLISkills.globalInstallEnabled = on
                        Task.detached(priority: .utility) { ClaudeCLISkills.syncGlobalInstall() }
                    }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.black.opacity(AppTheme.Opacity.muted)))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
            if !ClaudeCLISkills.bundledSkillNames().isEmpty {
                Text(ClaudeCLISkills.bundledSkillNames().joined(separator: " · "))
                    .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
    }

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Chat Backend")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Picker("", selection: $backend) {
                ForEach(ChatBackend.allCases, id: \.self) { b in
                    Text(b.shortName).tag(b)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: backend) { _, newValue in ChatBackend.selected = newValue }

            if backend == .claudeCLI {
                claudeCLIStatusRow
                claudeCLIModelPicker
            } else if backend == .zai {
                zaiModelPicker
            }
        }
    }

    private var claudeCLIStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(claudeFound ? Color.green : AppTheme.Text.mutedColor)
                .frame(width: 8, height: 8)
            Text(claudeFound
                 ? "claude found — uses your Claude Code subscription"
                 : "claude not found on PATH")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(AppTheme.Opacity.muted)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
    }

    private var claudeCLIModelPicker: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Model")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Picker("", selection: $cliModel) {
                ForEach([AnthropicModel.haiku45, .sonnet46, .opus48], id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: cliModel) { _, newValue in ClaudeCLIModelPreference.value = newValue }
        }
    }

    private var zaiModelPicker: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Model")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Picker("", selection: $zaiModel) {
                ForEach(ZaiModel.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: zaiModel) { _, v in ZaiModelPreference.value = v }
        }
    }

    private var apiKeySection: some View {
        SecureAPIKeyRow(
            title: "Anthropic API Key",
            description: "Used your own API key for the AI chat. Stored in your macOS Keychain.",
            getKeyURL: consoleURL,
            getKeyLabel: "Get Anthropic API key",
            placeholderPrefix: "sk-ant-...",
            hasKey: anthropicHasKey,
            maskedKey: anthropicMasked,
            draft: $anthropicDraft,
            onSave: saveAnthropic,
            onRemove: removeAnthropic
        )
    }

    private var zaiKeySection: some View {
        SecureAPIKeyRow(
            title: "z.ai API Key",
            description: "Use the GLM Coding Plan for the AI chat. Stored in your macOS Keychain.",
            getKeyURL: zaiSubscribeURL,
            getKeyLabel: "Get z.ai key",
            placeholderPrefix: "...",
            hasKey: zaiHasKey,
            maskedKey: zaiMasked,
            draft: $zaiDraft,
            onSave: saveZai,
            onRemove: removeZai
        )
    }

    private func refresh() {
        Task { @MainActor in
            async let aKey = Self.load(AnthropicKeychain.load)
            async let zKey = Self.load(ZaiKeychain.load)
            let (a, z) = (await aKey, await zKey)
            anthropicHasKey = !a.isEmpty
            anthropicMasked = Self.mask(a)
            zaiHasKey = !z.isEmpty
            zaiMasked = Self.mask(z)
            claudeFound = CLILocator(tool: "claude").resolve(override: nil) != nil
        }
    }

    private static func load(_ loader: @escaping @Sendable () -> String?) async -> String {
        await Task.detached(priority: .utility) { loader() ?? "" }.value
    }

    private func saveAnthropic() {
        let key = anthropicDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        anthropicDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { AnthropicKeychain.save(key) }.value
            anthropicHasKey = true
            anthropicMasked = Self.mask(key)
        }
    }

    private func removeAnthropic() {
        anthropicDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { AnthropicKeychain.delete() }.value
            anthropicHasKey = false
            anthropicMasked = ""
        }
    }

    private func saveZai() {
        let key = zaiDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        zaiDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { ZaiKeychain.save(key) }.value
            zaiHasKey = true
            zaiMasked = Self.mask(key)
        }
    }

    private func removeZai() {
        zaiDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { ZaiKeychain.delete() }.value
            zaiHasKey = false
            zaiMasked = ""
        }
    }

    private static func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }

    // MARK: - MCP server

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            mcpHeader
            mcpStatusRow
        }
    }

    private var mcpHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("MCP Server")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Lets external clients like Cursor, Claude Desktop, Claude Code, and Codex edit your timeline.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: openInstructions) {
                    HStack(spacing: 2) {
                        Text("Setup instructions")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    private var mcpStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill((appState.mcpService?.isRunning ?? false) ? Color.green : AppTheme.Text.mutedColor)
                    .frame(width: 8, height: 8)

                if appState.mcpService?.isRunning ?? false {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("Running on ")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text("127.0.0.1:\(String(MCPService.port))")
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                } else {
                    Text("Stopped")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { (appState.mcpService?.isRunning ?? false) },
                    set: { appState.setMCPEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func openInstructions() {
        HelpWindowController.shared.show(tab: .mcp)
    }
}
