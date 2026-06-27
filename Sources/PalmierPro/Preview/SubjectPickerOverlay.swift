import SwiftUI

/// Click-to-pick overlay for Subject Lock: dims the preview and draws a tappable, labeled
/// rectangle per detected object. Tapping one commits the seed. When nothing is detected (or the
/// user prefers), dragging draws a region to track. A click with no drag / Esc cancels.
struct SubjectPickerOverlay: View {
    @Environment(EditorViewModel.self) var editor
    @State private var hoveredId: Int?
    @State private var drawStart: CGPoint?
    @State private var drawCurrent: CGPoint?

    var body: some View {
        if let session = editor.activeSubjectPicker, let clip = clip(for: session) {
            GeometryReader { geo in
                let videoRect = videoContentRect(in: geo.size)
                let xform = clip.transformAt(frame: editor.activeFrame)
                let clipRect = clipFrame(xform, videoRect: videoRect)
                ZStack {
                    // Dim + drag surface. A drag draws a region; a near-zero drag (a click) cancels.
                    Color.black.opacity(AppTheme.Opacity.moderate)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    drawStart = v.startLocation
                                    drawCurrent = v.location
                                }
                                .onEnded { v in
                                    let dist = hypot(v.translation.width, v.translation.height)
                                    let rect = drawRect
                                    drawStart = nil; drawCurrent = nil
                                    // A near-zero drag is a click → cancel; a real drag → track the region.
                                    guard dist >= AppTheme.Spacing.md, let r = rect else {
                                        editor.cancelSubjectPick(); return
                                    }
                                    editor.commitSubjectDraw(
                                        box: sourceBox(from: r, clipRect: clipRect, rotationDeg: xform.rotation))
                                }
                        )

                    // Detected boxes — source-normalized, mapped into the clip's transform rect and
                    // rotated with it. Crop only masks edges, so source coords still map 1:1 here.
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

                    // In-progress drawn region.
                    if let r = drawRect {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Accent.spotlight, lineWidth: AppTheme.BorderWidth.thick)
                            .background(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .fill(AppTheme.Accent.spotlight.opacity(AppTheme.Opacity.faint)))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .allowsHitTesting(false)
                    }

                    hint(noObjects: session.objects.isEmpty)
                        .position(x: videoRect.midX, y: videoRect.minY + AppTheme.Spacing.xl)
                }
            }
            .onExitCommand { editor.cancelSubjectPick() }
        }
    }

    private var drawRect: CGRect? {
        guard let s = drawStart, let c = drawCurrent else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
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

    private func hint(noObjects: Bool) -> some View {
        Text(noObjects
             ? "No objects found — drag to select an area to track · Esc to cancel"
             : "Click a subject, or drag to select an area · Esc to cancel")
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

    /// A drawn screen rect → source-normalized TOP-LEFT box (inverse of the forward mapping:
    /// un-rotate about the clip center, then normalize within the clip's transform rect).
    private func sourceBox(from screenRect: CGRect, clipRect: CGRect, rotationDeg: Double) -> CGRect {
        let center = CGPoint(x: clipRect.midX, y: clipRect.midY)
        let rad = -rotationDeg * .pi / 180
        func unrot(_ p: CGPoint) -> CGPoint {
            let dx = p.x - center.x, dy = p.y - center.y
            return CGPoint(x: center.x + dx * cos(rad) - dy * sin(rad),
                           y: center.y + dx * sin(rad) + dy * cos(rad))
        }
        let a = unrot(CGPoint(x: screenRect.minX, y: screenRect.minY))
        let b = unrot(CGPoint(x: screenRect.maxX, y: screenRect.maxY))
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y)
        guard clipRect.width > 0, clipRect.height > 0 else { return .zero }
        return CGRect(
            x: (minX - clipRect.minX) / clipRect.width,
            y: (minY - clipRect.minY) / clipRect.height,
            width: (maxX - minX) / clipRect.width,
            height: (maxY - minY) / clipRect.height
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
