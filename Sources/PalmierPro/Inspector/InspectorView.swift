import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(EditorViewModel.self) var editor

    enum ClipTab: String, Hashable {
        case text = "Text"
        case video = "Video"
        case effects = "Adjust"
        case audio = "Audio"
        case ai = "AI Edit"
    }

    enum AssetTab: String, Hashable {
        case details = "Details"
        case ai = "AI Edit"
    }

    @State private var preferredTab: ClipTab = .video
    @State private var preferredAssetTab: AssetTab = .details
    @State private var transformExpanded = true
    @State var collapsedAdjustSections: Set<String> = ["Curves", "Color Wheels", "Hue Curves", "LUTs", "Effects"]
    @State var collapsedAdjustSubgroups: Set<String> = [
        "Detail", "Blur", "Motion Blur", "Vignette", "Film Grain", "Glow", "Chroma Key",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editor.isMarqueeSelecting {
                marqueeSelectionSummary
            } else if selectedVisualClip != nil || selectedAudioClip != nil {
                clipInspectorContent()
            } else if let asset = selectedMediaAsset {
                mediaAssetInspectorContent(asset)
            } else {
                projectMetadataContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: editor.selectedClipIds) { _, _ in
            if !editor.isMarqueeSelecting { resolvePreferredTab() }
        }
        .onChange(of: editor.isMarqueeSelecting) { _, selecting in
            if !selecting { resolvePreferredTab() }
        }
        .onChange(of: preferredTab) { _, newTab in
            if newTab != .video { editor.cropEditingActive = false }
        }
    }

    private var marqueeSelectionSummary: some View {
        VStack {
            Spacer()
            Text("\(editor.selectedClipIds.count) selected")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolvePreferredTab() {
        let isSingleText = selectedVisualClips.count + selectedAudioClips.count == 1
            && selectedVisualClip?.mediaType == .text
        if isSingleText {
            preferredTab = .text
        } else if preferredTab == .text {
            preferredTab = .video
        }
        editor.cropEditingActive = false
    }

    // MARK: - Project Metadata

    private var projectMetadataContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                metadataSection(title: "Project") {
                    if let url = editor.projectURL {
                        plainMetadataRow(
                            label: "Name",
                            value: url.deletingPathExtension().lastPathComponent
                        )
                        plainMetadataRow(
                            label: "Path",
                            value: url.path,
                            truncate: .middle
                        )
                    }
                    plainMetadataRow(label: "Duration", value: formatDuration(Double(editor.timeline.totalFrames) / Double(editor.timeline.fps)))
                }

                metadataSection(title: "Settings") {
                    menuMetadataRow(label: "Resolution", value: "\(editor.timeline.width) × \(editor.timeline.height)") { qualityMenuItems }
                    menuMetadataRow(label: "Frame Rate", value: "\(editor.timeline.fps) fps") { fpsMenuItems }
                    menuMetadataRow(label: "Aspect Ratio", value: formatAspectRatio(width: editor.timeline.width, height: editor.timeline.height)) { aspectMenuItems }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            VStack(spacing: AppTheme.Spacing.sm) {
                content()
            }
        }
    }

    private func plainMetadataRow(
        label: String,
        value: String,
        valueHelp: String? = nil,
        truncate: Text.TruncationMode = .tail
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize()
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(truncate)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .help(valueHelp ?? value)
                .padding(.horizontal, AppTheme.Spacing.xs)
        }
        .frame(height: AppTheme.IconSize.md)
    }

    private func formatAspectRatio(width: Int, height: Int) -> String {
        let gcd = gcd(width, height)
        return "\(width / gcd):\(height / gcd)"
    }

    private func menuMetadataRow<MenuContent: View>(
        label: String,
        value: String,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize()
            Spacer()
            Menu {
                menu()
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(value)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .padding(.horizontal, AppTheme.Spacing.xs)
                .frame(height: AppTheme.IconSize.md)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var aspectMenuItems: some View {
        ForEach(AspectPreset.allCases, id: \.self) { preset in
            Button {
                editor.applyTimelineSettings(fps: editor.timeline.fps, width: preset.width, height: preset.height)
            } label: {
                HStack {
                    Text(preset.label)
                    Spacer()
                    if editor.timeline.width == preset.width && editor.timeline.height == preset.height {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fpsMenuItems: some View {
        ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
            Button {
                editor.applyTimelineSettings(fps: fps, width: editor.timeline.width, height: editor.timeline.height)
            } label: {
                HStack {
                    Text("\(fps) fps")
                    Spacer()
                    if editor.timeline.fps == fps {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var qualityMenuItems: some View {
        ForEach(QualityPreset.allCases, id: \.self) { preset in
            Button {
                let (w, h) = preset.resolution(currentWidth: editor.timeline.width, currentHeight: editor.timeline.height)
                editor.applyTimelineSettings(fps: editor.timeline.fps, width: w, height: h)
            } label: {
                HStack {
                    Text(preset.label)
                    Spacer()
                    if preset.matches(width: editor.timeline.width, height: editor.timeline.height) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    // MARK: - Clip Inspector

    private var availableTabs: [ClipTab] {
        let visuals = selectedVisualClips
        let audios = selectedAudioClips
        let nonText = nonTextVisualClips
        let isSingle = visuals.count + audios.count == 1
        let isSingleText = isSingle && visuals.first?.mediaType == .text

        var tabs: [ClipTab] = []
        if isSingleText { tabs.append(.text) }
        if !nonText.isEmpty {
            tabs.append(.video)
            tabs.append(.effects)
        }
        if !audios.isEmpty { tabs.append(.audio) }
        if aiEditEligible && !AccountService.shared.isMisconfigured { tabs.append(.ai) }
        return tabs
    }

    /// True when the selection resolves to a single AI-editable visual clip.
    /// A linked video+audio pair counts as one
    private var aiEditEligible: Bool {
        let visuals = selectedVisualClips
        let audios = selectedAudioClips
        guard visuals.count == 1, resolvedClipAsset != nil else { return false }
        if audios.isEmpty { return true }
        let partners = Set(editor.linkedPartnerIds(of: visuals[0].id))
        return audios.allSatisfy { partners.contains($0.id) }
    }

    /// Tab the view actually renders (preferred if valid, else first available).
    private var activeTab: ClipTab? {
        let tabs = availableTabs
        return tabs.contains(preferredTab) ? preferredTab : tabs.first
    }

    /// The visual-or-image MediaAsset backing the currently selected visual clip.
    private var resolvedClipAsset: MediaAsset? {
        guard let clip = selectedVisualClip, clip.mediaType.isVisual else { return nil }
        return editor.mediaAssets.first { $0.id == clip.mediaRef }
    }

    var nonTextVisualClips: [Clip] {
        selectedVisualClips.filter { $0.mediaType != .text }
    }

    @ViewBuilder
    private func clipInspectorContent() -> some View {
        let tabs = availableTabs
        VStack(spacing: 0) {
            if tabs.count > 1 {
                tabBar(tabs)
            }
            Group {
                if activeTab == .ai, let asset = resolvedClipAsset {
                    AIEditTab(asset: asset, clipId: selectedVisualClip?.id)
                } else if activeTab == .effects {
                    ScrollView { effectsTabContent() }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                            switch activeTab {
                            case .text:
                                if let v = selectedVisualClip, v.mediaType == .text { TextTab(clip: v) }
                            case .video:
                                videoTabContent()
                            case .audio:
                                audioTabContent()
                            case .effects, .ai, .none:
                                EmptyView()
                            }
                        }
                        .padding(AppTheme.Spacing.lg)
                    }
                }
            }
        }
    }

    private func tabBar(_ tabs: [ClipTab]) -> some View {
        genericTabBar(titles: tabs.map(\.rawValue), selected: activeTab?.rawValue, raisedBackground: true) { title in
            if let tab = tabs.first(where: { $0.rawValue == title }) { preferredTab = tab }
        }
    }

    private func assetTabBar(_ tabs: [AssetTab]) -> some View {
        genericTabBar(titles: tabs.map(\.rawValue), selected: preferredAssetTab.rawValue, raisedBackground: true) { title in
            if let tab = tabs.first(where: { $0.rawValue == title }) { preferredAssetTab = tab }
        }
    }

    private func genericTabBar(
        titles: [String], selected: String?,
        raisedBackground: Bool = false,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ForEach(titles, id: \.self) { title in
                let isActive = selected == title
                let isAI = title == "AI Edit"
                let foreground: AnyShapeStyle = isAI
                    ? AnyShapeStyle(AppTheme.aiGradient.opacity(isActive ? 1 : 0.6))
                    : AnyShapeStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                Button {
                    onSelect(title)
                } label: {
                    VStack(spacing: AppTheme.Spacing.xs) {
                        Text(title)
                            .font(.system(size: AppTheme.FontSize.sm, weight: isActive ? .medium : .regular))
                            .foregroundStyle(foreground)
                        Rectangle()
                            .fill(isActive ? foreground : AnyShapeStyle(Color.clear))
                            .frame(height: AppTheme.BorderWidth.medium)
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.top, AppTheme.Spacing.xs)
        .background(raisedBackground ? AppTheme.Background.raisedColor : Color.clear)
        .overlay(alignment: .bottom) {
            if raisedBackground {
                Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.thin)
            }
        }
    }

    @ViewBuilder
    private func videoTabContent() -> some View {
        let clips = nonTextVisualClips
        let single = clips.count == 1 ? clips.first : nil
        let kfVisible = single != nil && editor.keyframesPanelVisible

        if let clip = single, kfVisible {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    transformSection(clips: clips)
                    speedSection(clips: clips + selectedAudioClips)
                        .padding(.trailing, KeyframesMetrics.controlsColumnWidth + AppTheme.Spacing.sm)
                    stabilizationSection(clips: clips)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, AppTheme.Spacing.sm)
                Divider()
                KeyframesPanel(clip: clip)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, AppTheme.Spacing.sm)
            }
        } else {
            transformSection(clips: clips)
            speedSection(clips: clips + selectedAudioClips)
            stabilizationSection(clips: clips)
        }

        keyframesToggleBar(enabled: single != nil)
    }

    func keyframesToggleBar(enabled: Bool) -> some View {
        let on = editor.keyframesPanelVisible
        return HStack {
            Spacer()
            Button {
                editor.keyframesPanelVisible.toggle()
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: on ? "diamond.fill" : "diamond")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    Text("Keyframes")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                }
                .foregroundStyle(on ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(enabled ? (on ? "Hide keyframe timeline" : "Show keyframe timeline") : "Select a single clip to enable")
        }
    }

    @ViewBuilder
    func stabilizationSection(clips: [Clip]) -> some View {
        if clips.count == 1, let clip = clips.first, clip.mediaType == .video {
            let stab = clip.stabilization
            let canStabilize = clip.speed == 1.0
            let analyzeProgress = editor.stabilizationManager.progressByAsset[clip.mediaRef]
            let bakeProgress = editor.stabilizationManager.bakeProgress[clip.mediaRef]
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                sectionTitleLabel(title: "Stabilization")
                propertyRow(label: "Stabilize") {
                    Toggle("", isOn: Binding(
                        get: { stab?.enabled ?? false },
                        set: { on in
                            updateStabilization(clip: clip) { $0.enabled = on }
                            if on { triggerStabilization(clip) }
                        }))
                    .labelsHidden()
                    .disabled(!canStabilize)
                }
                if stab?.enabled == true {
                    propertyRow(label: "Engine") {
                        Picker("", selection: Binding(
                            get: { stab?.engine ?? .vidstab },
                            set: { v in
                                updateStabilization(clip: clip) { $0.engine = v }
                                switch v {
                                case .vidstab:
                                    editor.cancelSubjectPick()
                                    editor.cancelPointPick()
                                    triggerBake(clip: clip, smoothness: stab?.smoothness ?? 0.5)
                                case .subject:
                                    editor.cancelPointPick()
                                    // Subject Lock needs a user-picked seed; prompt the pick when none exists yet.
                                    if clip.stabilization?.subjectSeed == nil {
                                        editor.beginSubjectPick(clip: clip)
                                    } else {
                                        triggerSubjectTrack(clip)
                                    }
                                case .points:
                                    editor.cancelSubjectPick()
                                    // Point Track needs user-placed points; enter placing mode when none exist yet.
                                    if clip.stabilization?.pointsSeed == nil {
                                        editor.beginPointPick(clip: clip)
                                    } else {
                                        triggerPointsTrack(clip)
                                    }
                                default:
                                    editor.cancelSubjectPick()
                                    editor.cancelPointPick()
                                }
                            })) {
                            ForEach(StabEngine.allCases, id: \.self) { eng in
                                Text(engineLabel(eng))
                                    .tag(eng)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if stab?.engine == .vidstab {
                        switch VidStab.capability {
                        case .none:
                            Text("Install ffmpeg to use this engine.")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        case .deshake:
                            Text("Install libvidstab-enabled ffmpeg for higher-quality vid.stab.")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        case .vidstab:
                            EmptyView()
                        }
                    }
                    if stab?.engine == .subject {
                        propertyRow(label: "Subject") {
                            Button(stab?.subjectSeed == nil ? "Choose subject…" : "Change subject…") {
                                editor.beginSubjectPick(clip: clip)
                            }
                            .buttonStyle(.capsule(.secondary, size: .small))
                        }
                        Text(stab?.subjectSeed.map { "Tracking: \($0.label)" } ?? "No subject selected")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        if let p = editor.stabilizationManager.progressByAsset[clip.mediaRef], p < 1, stab?.subjectSeed != nil {
                            Text("Tracking subject… \(Int(p * 100))%")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        propertyRow(label: "Smoothing") {
                            Picker("", selection: Binding(
                                get: { stab?.subjectSmoothing ?? .cinematic },
                                set: { v in updateStabilization(clip: clip) { $0.subjectSmoothing = v } })) {
                                ForEach(SubjectSmoothing.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        propertyRow(label: "Lock axis") {
                            Picker("", selection: Binding(
                                get: { stab?.subjectLockAxis ?? .both },
                                set: { v in updateStabilization(clip: clip) { $0.subjectLockAxis = v } })) {
                                ForEach(SubjectLockAxis.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        propertyRow(label: "Show tracking") {
                            Toggle("", isOn: Binding(
                                get: { editor.subjectTrackingPreview },
                                set: { editor.subjectTrackingPreview = $0 }))
                            .labelsHidden()
                        }
                    }
                    if stab?.engine == .points {
                        propertyRow(label: "Points") {
                            Button(stab?.pointsSeed == nil ? "Place points…" : "Edit points…") {
                                editor.beginPointPick(clip: clip)
                            }
                            .buttonStyle(.capsule(.secondary, size: .small))
                        }
                        Text(pointsCountLabel(stab?.pointsSeed))
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        if let p = editor.stabilizationManager.progressByAsset[clip.mediaRef], p < 1, stab?.pointsSeed != nil {
                            Text("Tracking points… \(Int(p * 100))%")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        if stab?.pointsSeed != nil {
                            propertyRow(label: "Track from seed") {
                                Picker("", selection: Binding(
                                    get: { stab?.pointsSeed?.direction ?? .both },
                                    set: { v in
                                        updateStabilization(clip: clip) { $0.pointsSeed?.direction = v }
                                        // Direction changes the tracked path → re-track. The captured
                                        // `clip` is stale, so build the seed with the new direction here.
                                        if var seed = clip.stabilization?.pointsSeed,
                                           let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) {
                                            seed.direction = v
                                            if !editor.stabilizationManager.hasPointsTrack(assetId: clip.mediaRef, seed: seed) {
                                                editor.stabilizationManager.enqueuePointsTrack(
                                                    assetId: clip.mediaRef, url: url, seed: seed)
                                            }
                                        }
                                    })) {
                                    ForEach(TrackDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                        propertyRow(label: "Smoothing") {
                            Picker("", selection: Binding(
                                get: { stab?.subjectSmoothing ?? .cinematic },
                                set: { v in updateStabilization(clip: clip) { $0.subjectSmoothing = v } })) {
                                ForEach(SubjectSmoothing.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        propertyRow(label: "Stabilize") {
                            Picker("", selection: Binding(
                                get: { stab?.subjectLockAxis ?? .both },
                                set: { v in updateStabilization(clip: clip) { $0.subjectLockAxis = v } })) {
                                ForEach(SubjectLockAxis.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        propertyRow(label: "Show tracking") {
                            Toggle("", isOn: Binding(
                                get: { editor.subjectTrackingPreview },
                                set: { editor.subjectTrackingPreview = $0 }))
                            .labelsHidden()
                        }
                    }
                    propertyRow(label: stab?.engine == .subject || stab?.engine == .points ? "Lock strength" : "Smoothness") {
                        Slider(value: Binding(
                            get: { stab?.smoothness ?? 0.5 },
                            set: { v in
                                updateStabilization(clip: clip) { $0.smoothness = v }
                                if stab?.engine == .vidstab {
                                    triggerBake(clip: clip, smoothness: v)
                                }
                            }),
                            in: 0...1)
                    }
                    propertyRow(label: "Crop to fit") {
                        Toggle("", isOn: Binding(
                            get: { stab?.cropToFit ?? true },
                            set: { v in updateStabilization(clip: clip) { $0.cropToFit = v } }))
                        .labelsHidden()
                    }
                    if let p = analyzeProgress, p < 1 {
                        Text("Analyzing… \(Int(p * 100))%")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    if let p = bakeProgress, p < 1 {
                        Text("Stabilizing… \(Int(p * 100))%")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
                if !canStabilize {
                    Text("Stabilization requires normal speed (1×).")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .onAppear { VidStab.detectIfNeeded() }   // probe off-main; never run ffmpeg in body
        }
    }

    private func engineLabel(_ eng: StabEngine) -> String {
        if eng == .vidstab {
            switch VidStab.capability {
            case .vidstab: return "vid.stab (FFmpeg)"
            case .deshake: return "FFmpeg (deshake)"
            case .none:    return "FFmpeg — needs ffmpeg"
            }
        }
        return eng.displayName
    }

    private func updateStabilization(clip: Clip, _ mutate: @escaping (inout Stabilization) -> Void) {
        editor.mutateClips(ids: [clip.id], actionName: "Stabilization") { c in
            var s = c.stabilization ?? Stabilization()
            mutate(&s)
            c.stabilization = s
        }
        editor.stabilizationManager.invalidateCache()
        editor.videoEngine?.refreshVisuals()
    }

    /// On enable, kick off the right work for the chosen engine.
    private func triggerStabilization(_ clip: Clip) {
        switch clip.stabilization?.engine ?? .vidstab {
        case .vidstab:
            triggerBake(clip: clip, smoothness: clip.stabilization?.smoothness ?? 0.5)
        case .subject:
            triggerSubjectTrack(clip)
        case .points:
            // Point Track must not run the global analyzer; place points (no seed) or track (has seed).
            if clip.stabilization?.pointsSeed == nil {
                editor.beginPointPick(clip: clip)
            } else {
                triggerPointsTrack(clip)
            }
        default:
            triggerStabilizationAnalysis(clip)
        }
    }

    private func pointsCountLabel(_ seed: PointsSeed?) -> String {
        guard let seed, !seed.points.isEmpty else { return "No points placed" }
        return "Tracking \(seed.points.count) point\(seed.points.count == 1 ? "" : "s")"
    }

    private func triggerStabilizationAnalysis(_ clip: Clip) {
        guard !editor.stabilizationManager.hasAnalysis(assetId: clip.mediaRef),
              let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { return }
        editor.stabilizationManager.analyze(assetId: clip.mediaRef, url: url)
    }

    private func triggerSubjectTrack(_ clip: Clip) {
        // Subject Lock no longer auto-tracks; it needs a user-picked seed (set by the picker UI).
        guard let seed = clip.stabilization?.subjectSeed,
              !editor.stabilizationManager.hasSubjectTrack(assetId: clip.mediaRef, seed: seed),
              let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { return }
        editor.stabilizationManager.enqueueSubjectTrack(assetId: clip.mediaRef, url: url, seed: seed)
    }

    private func triggerPointsTrack(_ clip: Clip) {
        guard let seed = clip.stabilization?.pointsSeed,
              !editor.stabilizationManager.hasPointsTrack(assetId: clip.mediaRef, seed: seed),
              let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { return }
        editor.stabilizationManager.enqueuePointsTrack(assetId: clip.mediaRef, url: url, seed: seed)
    }

    private func triggerBake(clip: Clip, smoothness: Double) {
        guard let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { return }
        editor.stabilizationManager.enqueueBake(assetId: clip.mediaRef, url: url, smoothness: smoothness)
    }

    @ViewBuilder
    func speedSection(clips: [Clip]) -> some View {
        if !clips.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                sectionTitleLabel(title: "Playback")
                propertyRow(label: "Speed") {
                    ScrubbableNumberField(
                        value: sharedClipValue(clips) { $0.speed },
                        range: 0.25...4.0,
                        format: "%.2f",
                        valueSuffix: "x",
                        dragSensitivity: 0.01,
                        fieldWidth: 50,
                        onChanged: { newVal in
                            for c in clips { editor.applyClipSpeed(clipId: c.id, newSpeed: newVal) }
                        }
                    ) { newVal in
                        editor.commitClipSpeed(ids: clips.map(\.id), newSpeed: newVal)
                    }
                }
            }
        }
    }

    func commitToClips(_ clips: [Clip], actionName: String, _ commit: (Clip) -> Void) {
        editor.undoManager?.beginUndoGrouping()
        for c in clips { commit(c) }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName(actionName)
    }

    // MARK: - Transform Section

    @ViewBuilder
    private func transformSection(clips: [Clip]) -> some View {
        let single = clips.count == 1 ? clips.first : nil
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            transformHeader(clips: clips)
                .frame(height: KeyframesMetrics.headerHeight, alignment: .leading)
            if transformExpanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    animatableRow(label: "Position", clipId: single?.id, property: .position) {
                        InspectorPositionFields(clips: clips)
                    }
                    animatableRow(label: "Scale", clipId: single?.id, property: .scale) {
                        scaleScrubField(clips: clips)
                    }
                    animatableRow(label: "Rotation", clipId: single?.id, property: .rotation) {
                        rotationScrubField(clips: clips)
                    }
                    animatableRow(label: "Opacity", clipId: single?.id, property: .opacity) {
                        opacityScrubField(clips: clips)
                    }
                    cropRow(single: single)
                    flipRow(clips: clips)
                }
                .padding(.leading, sectionContentIndent)
            }
        }
    }

    /// Property row with an optional keyframe stamp button after the value field.
    @ViewBuilder
    func animatableRow<Fields: View>(
        label: String,
        clipId: String?,
        property: AnimatableProperty,
        @ViewBuilder fields: () -> Fields
    ) -> some View {
        propertyRow(label: label) {
            HStack(spacing: AppTheme.Spacing.sm) {
                fields()
                if let clipId {
                    keyframeControls(clipId: clipId, property: property)
                }
            }
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }

    private func keyframeControls(clipId: String, property: AnimatableProperty) -> some View {
        let frame = editor.activeFrame
        let inRange = editor.clipFor(id: clipId)?.contains(timelineFrame: frame) ?? false
        let onKeyframe = editor.hasKeyframe(clipId: clipId, property: property, at: frame)
        let prev = editor.previousKeyframeFrame(clipId: clipId, property: property, before: frame)
        let next = editor.nextKeyframeFrame(clipId: clipId, property: property, after: frame)
        return HStack(spacing: 0) {
            keyframeNavButton(systemName: "chevron.left", help: "Go to previous keyframe", enabled: prev != nil) {
                if let f = prev { editor.seekToFrame(f) }
            }
            Button {
                if onKeyframe {
                    editor.removeKeyframe(clipId: clipId, property: property, at: frame)
                } else {
                    editor.stampKeyframe(clipId: clipId, property: property, frame: frame)
                }
            } label: {
                Image(systemName: onKeyframe ? "diamond.fill" : "diamond")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(onKeyframe ? AppTheme.Accent.timecodeColor : AppTheme.Text.tertiaryColor)
                    .frame(width: KeyframesMetrics.stampButtonWidth, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!inRange)
            .opacity(inRange ? 1 : 0.4)
            .help(!inRange ? "Move playhead inside the clip"
                  : onKeyframe ? "Remove keyframe at playhead"
                  : "Add keyframe at playhead")
            keyframeNavButton(systemName: "chevron.right", help: "Go to next keyframe", enabled: next != nil) {
                if let f = next { editor.seekToFrame(f) }
            }
        }
    }

    private func keyframeNavButton(
        systemName: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: KeyframesMetrics.navButtonWidth, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(help)
    }

    /// Rows sit flush-left under their uppercase section header.
    var sectionContentIndent: CGFloat { 0 }

    private func transformHeader(clips: [Clip]) -> some View {
        collapsibleHeader(
            title: "Transform",
            expanded: transformExpanded,
            onToggle: { transformExpanded.toggle() },
            resetHelp: transformExpanded ? "Reset transform" : nil,
            onReset: transformExpanded ? {
                commitToClips(clips, actionName: "Reset Transform") { c in
                    editor.commitClipProperty(clipId: c.id) {
                        $0.transform = Transform()
                        $0.opacity = 1
                        $0.opacityTrack = nil
                        $0.positionTrack = nil
                        $0.scaleTrack = nil
                        $0.rotationTrack = nil
                        $0.fadeInFrames = 0
                        $0.fadeOutFrames = 0
                        $0.fadeInInterpolation = .linear
                        $0.fadeOutInterpolation = .linear
                    }
                }
            } : nil
        )
    }

    @ViewBuilder
    private func scaleScrubField(clips: [Clip]) -> some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.sizeAt(frame: editor.activeFrame).width },
            range: 0.01...(.infinity),
            displayMultiplier: 100,
            format: "%.0f",
            valueSuffix: "%",
            fieldWidth: 50,
            onChanged: { newVal in
                for c in clips { editor.applyScale(clipId: c.id, newScale: newVal) }
            }
        ) { newVal in
            editor.undoManager?.beginUndoGrouping()
            for c in clips { editor.commitScale(clipId: c.id, newScale: newVal) }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Change Scale")
        }
    }

    @ViewBuilder
    private func rotationScrubField(clips: [Clip]) -> some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.rotationAt(frame: editor.activeFrame) },
            range: -3600...3600,
            displayMultiplier: 1,
            format: "%.0f",
            valueSuffix: "°",
            fieldWidth: 50,
            onChanged: { newVal in
                for c in clips { editor.applyRotation(clipId: c.id, valueDeg: newVal) }
            }
        ) { newVal in
            editor.undoManager?.beginUndoGrouping()
            for c in clips { editor.commitRotation(clipId: c.id, valueDeg: newVal) }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Change Rotation")
        }
    }

    @ViewBuilder
    private func opacityScrubField(clips: [Clip]) -> some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.rawOpacityAt(frame: editor.activeFrame) },
            range: 0...1,
            displayMultiplier: 100,
            format: "%.0f",
            valueSuffix: "%",
            fieldWidth: 50,
            onChanged: { newVal in
                for c in clips { editor.applyOpacity(clipId: c.id, value: newVal) }
            }
        ) { newVal in
            editor.undoManager?.beginUndoGrouping()
            for c in clips { editor.commitOpacity(clipId: c.id, value: newVal) }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Change Opacity")
        }
    }

    // MARK: - Section helpers

    private func collapsibleHeader(
        title: String,
        expanded: Bool,
        onToggle: @escaping () -> Void,
        resetHelp: String? = nil,
        onReset: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Button(action: onToggle) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    sectionTitleLabel(title: title)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if let onReset {
                resetButton(onReset: onReset, help: resetHelp)
            }
        }
    }

    func sectionTitleLabel(title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.Text.mutedColor)
            .fixedSize()
    }

    func resetButton(onReset: @escaping () -> Void, help: String?) -> some View {
        Button(action: onReset) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(help ?? "Reset")
    }

    func propertyRow<Trailing: View>(
        label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .fixedSize()
            Spacer()
            trailing()
        }
    }

    // MARK: - Flip

    @ViewBuilder
    private func flipRow(clips: [Clip]) -> some View {
        let activeH = clips.first?.transform.flipHorizontal ?? false
        let activeV = clips.first?.transform.flipVertical ?? false
        propertyRow(label: "Flip") {
            HStack(spacing: AppTheme.Spacing.xs) {
                iconToggleButton(
                    systemName: "arrow.left.and.right",
                    isOn: activeH,
                    help: activeH ? "Remove horizontal flip" : "Flip horizontally"
                ) {
                    let newValue = !activeH
                    commitToClips(clips, actionName: "Flip Horizontal") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.transform.flipHorizontal = newValue }
                    }
                }
                iconToggleButton(
                    systemName: "arrow.up.and.down",
                    isOn: activeV,
                    help: activeV ? "Remove vertical flip" : "Flip vertically"
                ) {
                    let newValue = !activeV
                    commitToClips(clips, actionName: "Flip Vertical") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.transform.flipVertical = newValue }
                    }
                }
            }
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }

    private func iconToggleButton(
        systemName: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(isOn ? AppTheme.Accent.primary : AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(Color.white.opacity(isOn ? AppTheme.Opacity.subtle : 0))
                )
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Crop

    @ViewBuilder
    private func cropRow(single: Clip?) -> some View {
        let editing = editor.cropEditingActive && single != nil
        let disabled = single == nil
        propertyRow(label: "Crop") {
            HStack(spacing: AppTheme.Spacing.sm) {
                iconToggleButton(
                    systemName: "crop",
                    isOn: editing,
                    help: disabled ? "Crop applies to one clip at a time"
                          : editing ? "Stop editing crop on canvas"
                          : "Edit crop on canvas"
                ) {
                    editor.cropEditingActive.toggle()
                }
                .disabled(disabled)
                cropMenu(single: single)
                if let cid = single?.id {
                    keyframeControls(clipId: cid, property: .crop)
                }
            }
        }
        .frame(height: KeyframesMetrics.rowHeight)
        .opacity(disabled ? 0.4 : 1)
    }

    @ViewBuilder
    private func cropMenu(single: Clip?) -> some View {
        let active = editor.cropAspectLock
        Menu {
            ForEach(CropAspectLock.allCases, id: \.self) { preset in
                Button {
                    if let clip = single { applyCropPreset(preset, on: clip) }
                } label: {
                    if preset == active {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(active.label)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(single == nil)
        .help("Choose a crop aspect")
    }

    private func applyCropPreset(_ preset: CropAspectLock, on clip: Clip) {
        editor.cropAspectLock = preset
        switch preset {
        case .free:
            // Don't mutate crop; user keeps current shape and drags freely.
            break
        case .original:
            editor.commitCrop(clipId: clip.id, newCrop: Crop())
        default:
            guard let target = preset.pixelAspect else { return }
            editor.commitCrop(clipId: clip.id, newCrop: editor.cropFittingAspect(for: clip, targetPixelAspect: target))
        }
    }

    // MARK: - Media Asset Inspector

    @ViewBuilder
    private func mediaAssetInspectorContent(_ asset: MediaAsset) -> some View {
        if asset.type.isVisual && !AccountService.shared.isMisconfigured {
            VStack(spacing: 0) {
                assetTabBar([.details, .ai])
                if preferredAssetTab == .ai {
                    AIEditTab(asset: asset)
                } else {
                    assetDetailsContent(asset)
                }
            }
        } else {
            assetDetailsContent(asset)
        }
    }

    @ViewBuilder
    private func assetDetailsContent(_ asset: MediaAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                assetIdentityHeader(asset)

                fileSection(asset)

                if let gen = asset.generationInput {
                    if GenerationReferencesStrip.hasResolvableReferences(gen, in: editor.mediaAssets) {
                        metadataSection(title: "References") {
                            GenerationReferencesStrip(generationInput: gen)
                        }
                    }

                    metadataSection(title: "Generated") {
                        plainMetadataRow(label: "Model", value: ModelRegistry.displayName(for: gen.model))
                        if !gen.aspectRatio.isEmpty {
                            plainMetadataRow(label: "Aspect Ratio", value: gen.aspectRatio)
                        }
                        if let resolution = gen.resolution {
                            plainMetadataRow(label: "Resolution", value: resolution)
                        }
                        if gen.duration > 0 {
                            plainMetadataRow(label: "Duration", value: "\(gen.duration)s")
                        }
                    }

                    if !gen.prompt.isEmpty {
                        promptSection(prompt: gen.prompt)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func fileSection(_ asset: MediaAsset) -> some View {
        metadataSection(title: "File") {
            plainMetadataRow(label: "Type", value: asset.type.trackLabel)
            if asset.type != .audio, let width = asset.sourceWidth, let height = asset.sourceHeight {
                plainMetadataRow(label: "Dimensions", value: "\(width) × \(height)")
            }
            if asset.duration > 0 && asset.type != .image {
                plainMetadataRow(label: "Duration", value: formatDuration(asset.duration))
            }
            if let fileSize = fileSize(for: asset.url) {
                plainMetadataRow(label: "Size", value: fileSize)
            }
            plainMetadataRow(
                label: "Path",
                value: asset.url.path,
                truncate: .middle
            )
        }
    }

    private func assetIdentityHeader(_ asset: MediaAsset) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text(asset.name)
                .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(2)
                .textSelection(.enabled)
            if asset.generationInput != nil {
                aiBadge
            }
            Spacer(minLength: 0)
        }
    }

    private var aiBadge: some View {
        Text("AI")
            .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.aiGradient)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(Color.white.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline)
            )
    }

    private func promptSection(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("PROMPT")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Spacer()
                PromptCopyButton(text: prompt)
            }
            Text(prompt)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metadataRow(_ icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(width: AppTheme.IconSize.xs)
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }


    // MARK: - Helpers

    private var selectedVisualClips: [Clip] {
        guard !editor.selectedClipIds.isEmpty else { return [] }
        var out: [Clip] = []
        for track in editor.timeline.tracks {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType.isVisual {
                out.append(clip)
            }
        }
        return out
    }

    var selectedAudioClips: [Clip] {
        guard !editor.selectedClipIds.isEmpty else { return [] }
        var out: [Clip] = []
        for track in editor.timeline.tracks {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType == .audio {
                out.append(clip)
            }
        }
        return out
    }

    private var selectedVisualClip: Clip? { selectedVisualClips.first }
    private var selectedAudioClip: Clip? { selectedAudioClips.first }

    private var selectedMediaAsset: MediaAsset? {
        guard editor.selectedMediaAssetIds.count == 1,
              let id = editor.selectedMediaAssetIds.first else { return nil }
        return editor.mediaAssets.first { $0.id == id }
    }


    private func fileSize(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

func sharedClipValue<T: Equatable>(_ clips: [Clip], _ extract: (Clip) -> T) -> T? {
    guard let first = clips.first else { return nil }
    let v = extract(first)
    for c in clips.dropFirst() where extract(c) != v { return nil }
    return v
}

// MARK: - Volume Scale

/// Maps a linear amplitude multiplier to dB for the volume slider.
/// Below the floor we snap to true 0 (hard mute) and render "-∞ dB".
enum VolumeScale {
    static let floorDb: Double = -60
    static let ceilingDb: Double = 15

    static func dbFromLinear(_ linear: Double) -> Double {
        guard linear > 0 else { return floorDb }
        return min(ceilingDb, max(floorDb, 20 * log10(linear)))
    }

    static func linearFromDb(_ db: Double) -> Double {
        guard db > floorDb else { return 0 }
        return pow(10, min(db, ceilingDb) / 20)
    }
}

struct PromptCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy prompt")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}
