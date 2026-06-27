import SwiftUI

/// Click-to-pick overlay for Subject Lock: dims the preview and draws a tappable, labeled
/// rectangle per detected object. Tapping one commits the seed; Esc / outside-tap cancels.
struct SubjectPickerOverlay: View {
    @Environment(EditorViewModel.self) var editor
    @State private var hoveredId: Int?

    var body: some View {
        if let session = editor.subjectPicker {
            GeometryReader { geo in
                let videoRect = videoContentRect(in: geo.size)
                ZStack {
                    Color.black.opacity(AppTheme.Opacity.moderate)
                        .contentShape(Rectangle())
                        .onTapGesture { editor.cancelSubjectPick() }

                    ForEach(session.objects) { object in
                        let rect = screenRect(object.box, in: videoRect)
                        let isHovered = hoveredId == object.id
                        box(object: object, rect: rect, isHovered: isHovered)
                    }

                    hint
                        .position(x: videoRect.midX, y: videoRect.minY + AppTheme.Spacing.xl)
                }
            }
            .onExitCommand { editor.cancelSubjectPick() }
        }
    }

    @ViewBuilder
    private func box(object: DetectedObject, rect: CGRect, isHovered: Bool) -> some View {
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
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
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

    /// Normalized TOP-LEFT box → screen rect inside the letterboxed video content rect.
    private func screenRect(_ box: CGRect, in videoRect: CGRect) -> CGRect {
        CGRect(
            x: videoRect.minX + box.minX * videoRect.width,
            y: videoRect.minY + box.minY * videoRect.height,
            width: box.width * videoRect.width,
            height: box.height * videoRect.height
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
