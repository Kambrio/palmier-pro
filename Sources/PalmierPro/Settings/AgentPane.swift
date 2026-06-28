import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var hasKey: Bool = false
    @State private var maskedKey: String = ""
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool
    @State private var backend: ChatBackend = ChatBackend.selected
    @State private var claudeFound: Bool = false
    @State private var cliModel: AnthropicModel = ClaudeCLIModelPreference.value

    private let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            backendSection
            Divider().overlay(AppTheme.Border.subtleColor)
            apiKeySection
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
            Divider().overlay(AppTheme.Border.subtleColor)
            skillsSection
            Divider().overlay(AppTheme.Border.subtleColor)
            transcriptSection
        }
        .onAppear(perform: refresh)
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
                    Text(b.displayName).tag(b)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: backend) { _, newValue in ChatBackend.selected = newValue }

            if backend == .claudeCLI {
                claudeCLIStatusRow
                claudeCLIModelPicker
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

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            keyField
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Anthropic API Key")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Used your own API key for the AI chat. Stored in your macOS Keychain.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { NSWorkspace.shared.open(consoleURL, configuration: .init(), completionHandler: nil) }) {
                    HStack(spacing: 2) {
                        Text("Get Anthropic API key")
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

    private var keyField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            fieldBox
            trailingControl
        }
    }

    private var fieldBox: some View {
        SecureField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit(save)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.black.opacity(AppTheme.Opacity.muted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isFocused)
    }

    private var placeholder: String {
        hasKey ? maskedKey : "sk-ant-..."
    }

    @ViewBuilder
    private var trailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save", action: save)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove API key")
        }
    }

    private func refresh() {
        Task { @MainActor in
            let key = await Self.loadKey()
            applyKey(key)
        }
    }

    private func applyKey(_ key: String) {
        hasKey = !key.isEmpty
        maskedKey = mask(key)
        claudeFound = CLILocator(tool: "claude").resolve(override: nil) != nil
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        draft = ""
        isFocused = false
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                AnthropicKeychain.save(key)
            }.value
            applyKey(key)
        }
    }

    private func remove() {
        draft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                AnthropicKeychain.delete()
            }.value
            applyKey("")
        }
    }

    private static func loadKey() async -> String {
        await Task.detached(priority: .utility) {
            AnthropicKeychain.load() ?? ""
        }.value
    }

    private func mask(_ key: String) -> String {
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
