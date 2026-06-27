import SwiftUI

/// Click-to-pick overlay for Subject Lock: dims the preview and draws a tappable, labeled
/// rectangle per detected object. Tapping one commits the seed; Esc / outside-tap cancels.
struct SubjectPickerOverlay: View {
    @Environment(EditorViewModel.self) var editor
    @State private var hoveredId: Int?

    var body: some View {
        if let session = editor.activeSubjectPicker, let clip = clip(for: session) {
            GeometryReader { geo in
                let videoRect = videoContentRect(in: geo.size)
                let xform = clip.transformAt(frame: editor.activeFrame)
                let clipRect = clipFrame(xform, videoRect: videoRect)
                ZStack {
                    Color.black.opacity(AppTheme.Opacity.moderate)
                        .contentShape(Rectangle())
                        .onTapGesture { editor.cancelSubjectPick() }

                    // Boxes are source-normalized; they map into the clip's transform rect and rotate
                    // with it. Crop only masks the clip's edges, so source coords still map 1:1 here.
                    ZStack {
                        ForEach(session.objects) { object in
                            let local = localRect(object.box, in: clipRect.size)
                            box(object: object, isHovered: hoveredId == object.id)
                                .frame(width: local.width, height: local.height)
                                .position(x: local.midX, y: local.midY)
                        }
                    }
                    .frame(width: clipRect.width, height: clipRect.height)
                    .rotationEffect(.degrees(xform.rotation))
                    .position(x: clipRect.midX, y: clipRect.midY)

                    hint
                        .position(x: videoRect.midX, y: videoRect.minY + AppTheme.Spacing.xl)
                }
            }
            .onExitCommand { editor.cancelSubjectPick() }
        }
    }

    private func clip(for session: SubjectPickerSession) -> Clip? {
        editor.timeline.tracks.flatMap(\.clips).first { $0.id == session.clipId }
    }

    @ViewBuilder
    private func box(object: DetectedObject, isHovered: Bool) -> some View {
        let accent = AppTheme.Accent.spotlight
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(accent, lineWidth: isHovered ? AppTheme.BorderWidth.thick : AppTheme.BorderWidth.medium)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(accent.opacity(isHovered ? AppTheme.Opacity.moderate : AppTheme.Opacity.faint))
                )

            chip(object: object)
                .padding(AppTheme.Spacing.xxs)
        }
        .contentShape(Rectangle())
        .onHover { hovering in hoveredId = hovering ? object.id : (hoveredId == object.id ? nil : hoveredId) }
        .onTapGesture { editor.commitSubjectPick(object: object) }
    }

    private func chip(object: DetectedObject) -> some View {
        Text("\(object.label) \(String(format: "%.2f", object.confidence))")
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(AppTheme.Accent.spotlight.opacity(AppTheme.Opacity.prominent), in: .rect(cornerRadius: AppTheme.Radius.xs))
    }

    private var hint: some View {
        Text("Click a subject to track · Esc to cancel")
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(Color.black.opacity(AppTheme.Opacity.strong), in: .capsule)
    }

    /// Normalized TOP-LEFT box → rect in the clip's local (unrotated) space.
    private func localRect(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: box.minX * size.width,
            y: box.minY * size.height,
            width: box.width * size.width,
            height: box.height * size.height
        )
    }

    /// The clip's full-frame display rect for `t` inside the letterboxed video content rect.
    private func clipFrame(_ t: Transform, videoRect: CGRect) -> CGRect {
        let tl = t.topLeft
        return CGRect(
            x: videoRect.origin.x + tl.x * videoRect.width,
            y: videoRect.origin.y + tl.y * videoRect.height,
            width: t.width * videoRect.width,
            height: t.height * videoRect.height
        )
    }

    private func videoContentRect(in viewSize: CGSize) -> CGRect {
        let videoAspect = CGFloat(editor.timeline.width) / CGFloat(editor.timeline.height)
        let viewAspect = viewSize.width / viewSize.height
        let w: CGFloat, h: CGFloat
        if viewAspect > videoAspect {
            h = viewSize.height; w = h * videoAspect
        } else {
            w = viewSize.width; h = w / videoAspect
        }
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }
}
