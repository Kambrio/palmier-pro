import SwiftUI

/// On-device voiceover generation (OmniVoice). Mirrors MusicTab's chassis: pick a voice
/// (clone from a selected clip, or a preset), a language, and a script; Generate places
/// the clip at the playhead. Not gated behind Palmier sign-in — OmniVoice is local/free.
struct VoiceoverTab: View {
    @Environment(EditorViewModel.self) var editor

    @State private var cloneMode: Bool = true
    @State private var language: String = "English"
    @State private var script: String = ""
    @State private var styleInstructions: String = ""
    @State private var isGenerating = false
    @State private var generatingLabel = "Generating voiceover…"
    @State private var note: String?
    @State private var refClipId: String?

    private let languages = [
        "English", "Spanish", "Russian", "Mandarin Chinese", "French", "German",
        "Japanese", "Korean", "Portuguese", "Italian", "Arabic", "Hindi",
        "Turkish", "Dutch", "Polish", "Ukrainian"
    ]

    private var model: AudioModelConfig { OmniVoiceCatalog.model }

    private var trimmedScript: String { script.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Snapshot of the clip to clone from. Captured when a single audio/video clip is selected,
    /// and held here so it survives the timeline selection being cleared on media-panel clicks
    /// (handlePanelClick clears selectedClipIds when the media panel is clicked — e.g. Generate).
    private var voiceClip: Clip? {
        let clips = editor.timeline.tracks.flatMap(\.clips)
        if let id = refClipId, let snap = clips.first(where: { $0.id == id }) { return snap }
        return clips.first {
            editor.selectedClipIds.contains($0.id) && ($0.mediaType == .video || $0.mediaType == .audio)
        }
    }
    private var voiceAsset: MediaAsset? {
        guard let mr = voiceClip?.mediaRef else { return nil }
        return editor.mediaAssets.first { $0.id == mr }
    }

    private func captureSelection(_ ids: Set<String>) {
        // A timeline click selects the clip AND its linked audio partner (expandToLinkGroup),
        // so don't require a single id — just grab the first selected video/audio clip.
        guard let clip = editor.timeline.tracks.flatMap(\.clips)
            .first(where: { ids.contains($0.id) && ($0.mediaType == .video || $0.mediaType == .audio) })
        else { return }
        refClipId = clip.id
    }

    private var voiceSummary: String {
        guard let clip = voiceClip, let asset = voiceAsset else { return "No clip selected" }
        let fps = max(1, editor.timeline.fps)
        return "\(asset.name) · \(clock(Double(clip.startFrame) / Double(fps)))"
    }

    private var placementFrame: Int {
        editor.validSelectedTimelineRange?.startFrame ?? editor.currentFrame
    }

    /// Rough TTS estimate for the placeholder clip; finalized to the real duration on completion.
    private var estimatedSeconds: Double { max(3.0, Double(trimmedScript.count) / 15.0) }

    private var validationNote: String? {
        if trimmedScript.isEmpty { return "Enter the script to speak." }
        if cloneMode && voiceClip == nil { return "Select a clip on the timeline whose voice to clone." }
        if !cloneMode && styleInstructions.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Describe a preset voice (e.g. “female”, “british accent”)."
        }
        return nil
    }
    private var canGenerate: Bool { validationNote == nil && !isGenerating }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                        voiceSection
                        languageSection
                        scriptSection
                        modelSection
                    }
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.top, AppTheme.Spacing.md)
                    .padding(.bottom, AppTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: generatingLabel, size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .onAppear { captureSelection(editor.selectedClipIds) }
        .onChange(of: editor.selectedClipIds) { _, ids in captureSelection(ids) }
    }

    // MARK: - Sections

    private var voiceSection: some View {
        InspectorSection("Voice") {
            InspectorRow(icon: "person.wave.2", label: "Input") {
                Menu {
                    Button("Clone from clip") { cloneMode = true }
                    Button("Preset voice") { cloneMode = false }
                } label: { menuValueLabel(cloneMode ? "Clone from clip" : "Preset voice") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
            }
            if cloneMode {
                InspectorRow(
                    icon: "film",
                    label: "Reference clip",
                    labelHelp: "Select a clip on the timeline whose voice to clone. Works from the local proxy when the original footage is offline."
                ) { valueText(voiceSummary) }
            } else {
                InspectorRow(
                    icon: "slider.horizontal.3",
                    label: "Style",
                    labelHelp: "Voice-design tokens OmniVoice accepts, e.g. “female”, “male”, “british accent”, “child”, “elderly”."
                ) {
                    TextField("female, british accent", text: $styleInstructions, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                }
            }
        }
    }

    private var languageSection: some View {
        InspectorSection("Language") {
            InspectorRow(icon: "globe", label: "Language") {
                Menu {
                    ForEach(languages, id: \.self) { lang in
                        Button(lang) { language = lang }
                    }
                } label: { menuValueLabel(language) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
            }
        }
    }

    private var scriptSection: some View {
        InspectorSection("Script") {
            TextEditor(text: $script)
                .scrollContentBackground(.hidden)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .frame(minHeight: 96)
                .padding(AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Background.raisedColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        }
    }

    private var modelSection: some View {
        InspectorSection("Model") {
            InspectorRow(icon: "waveform", label: "Model") { valueText(model.displayName) }
        }
    }

    // MARK: - Generate bar

    private var generateBar: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            if let note = note ?? validationNote {
                Text(note)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(action: generate) {
                    Text("Generate")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Background.baseColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.smMd)
                        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Accent.primary))
                        .opacity(canGenerate ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
                }
                .buttonStyle(.plain).focusable(false)
                .disabled(!canGenerate)

                agentMenu
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private var agentMenu: some View {
        Menu {
            Button {
                agentTask("Generate a short voiceover intro for my video and place it at the playhead. Use the OmniVoice local model.")
            } label: { Label("Voiceover intro", systemImage: "person.wave.2") }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Agent Mode")
                Image(systemName: "chevron.down").font(.system(size: AppTheme.FontSize.xs))
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.aiGradient)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.aiGradient.opacity(AppTheme.Opacity.medium), lineWidth: AppTheme.BorderWidth.thin))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
        .help("Let Agent write and generate the voiceover for you.")
    }

    private func agentTask(_ prompt: String) {
        let service = editor.agentService
        service.newChat()
        service.draft = prompt
        editor.agentPanelVisible = true
    }

    // MARK: - Generate

    private func generate() {
        note = nil
        let trimmed = trimmedScript
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        generatingLabel = "Generating voiceover…"
        let clone = cloneMode
        let lang = language
        let style = styleInstructions.trimmingCharacters(in: .whitespaces).isEmpty ? nil : styleInstructions
        let start = placementFrame
        let estimate = estimatedSeconds
        Task {
            do {
                var voicePath: String? = nil
                if clone {
                    guard let clip = voiceClip, let asset = voiceAsset else { throw OmniVoiceCloneError.offline }
                    let fps = max(1, editor.timeline.fps)
                    let startSec = Double(clip.trimStartFrame) / Double(fps)
                    let durSec = min(30.0, Double(clip.durationFrames) / Double(fps))
                    let ref = try await OmniVoiceCloneResolver.makeRefAudio(
                        mediaRef: asset.id, isVideo: asset.type == .video,
                        startSeconds: startSec, durationSeconds: durSec,
                        resolver: editor.mediaResolver, ffmpegPath: VidStab.ffmpegPath())
                    voicePath = ref.path
                }
                var genInput = GenerationInput(
                    prompt: trimmed, model: OmniVoiceCatalog.modelId, duration: 0, aspectRatio: "",
                    resolution: nil, voice: voicePath, lyrics: nil,
                    styleInstructions: clone ? nil : style, instrumental: nil)
                genInput.language = lang
                let params = AudioGenerationParams(
                    prompt: trimmed, voice: nil, lyrics: nil,
                    styleInstructions: clone ? nil : style, instrumental: false, durationSeconds: nil)
                let placeholderId = AudioGenerationSubmission.make(
                    genInput: genInput, model: model, params: params,
                    name: nil, folderId: editor.mediaPanelCurrentFolderId
                ).submit(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: { asset in
                        editor.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                    }
                )
                editor.placeGeneratingAudioClip(
                    placeholderId: placeholderId, startFrame: start,
                    spanSeconds: estimate, actionName: "Add voiceover"
                )
                isGenerating = false
            } catch {
                note = error.localizedDescription
                isGenerating = false
            }
        }
    }

    // MARK: - Helpers

    private func menuValueLabel(_ text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: AppTheme.FontSize.xxs))
        }
        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .lineLimit(1)
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .lineLimit(1)
    }

    private func clock(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
