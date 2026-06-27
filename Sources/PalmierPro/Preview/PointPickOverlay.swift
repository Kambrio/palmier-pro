import SwiftUI

/// Click-to-place overlay for Point Track: dims the preview and lets the user tap empty space to add
/// a tracking dot, drag a dot to move it, and click a dot to remove it. A "Track N points" button
/// (or ⏎) confirms; Esc cancels. All dots are stored source-normalized (TOP-LEFT) and mapped through
/// the clip's transform rect (including rotation).
struct PointPickOverlay: View {
    @Environment(EditorViewModel.self) var editor

    private let space = "pointpick"

    var body: some View {
        if let session = editor.activePointPick, let clip = clip(for: session) {
            GeometryReader { geo in
                let videoRect = videoContentRect(in: geo.size)
                let xform = clip.transformAt(frame: editor.activeFrame)
                let clipRect = clipFrame(xform, videoRect: videoRect)
                ZStack {
                    // Dim + tap surface. A near-zero drag (a click) on empty space adds a dot.
                    Color.black.opacity(AppTheme.Opacity.moderate)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                                .onEnded { v in
                                    let dist = hypot(v.translation.width, v.translation.height)
                                    guard dist < AppTheme.Spacing.md else { return }
                                    editor.addPointPick(
                                        sourcePoint(from: v.location, clipRect: clipRect, rotationDeg: xform.rotation))
                                }
                        )

                    ForEach(Array(session.points.enumerated()), id: \.offset) { idx, p in
                        dot(index: idx, clipRect: clipRect, rotationDeg: xform.rotation)
                            .position(screenPoint(p, clipRect: clipRect, rotationDeg: xform.rotation))
                    }

                    hint()
                        .position(x: videoRect.midX, y: videoRect.minY + AppTheme.Spacing.xl)
                    confirmButton(count: session.points.count)
                        .position(x: videoRect.midX, y: videoRect.maxY - AppTheme.Spacing.xl)
                }
                .coordinateSpace(.named(space))
            }
            .onExitCommand { editor.cancelPointPick() }
        }
    }

    private func clip(for session: PointPickSession) -> Clip? {
        editor.timeline.tracks.flatMap(\.clips).first { $0.id == session.clipId }
    }

    private func dot(index: Int, clipRect: CGRect, rotationDeg: Double) -> some View {
        Circle()
            .fill(AppTheme.Accent.spotlight)
            .overlay(Circle().strokeBorder(.white, lineWidth: AppTheme.BorderWidth.medium))
            .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
            .shadow(AppTheme.Shadow.sm)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { v in
                        editor.movePointPick(
                            index: index,
                            to: sourcePoint(from: v.location, clipRect: clipRect, rotationDeg: rotationDeg))
                    }
                    .onEnded { v in
                        // A near-zero drag is a click → remove; a real drag already moved the dot.
                        if hypot(v.translation.width, v.translation.height) < AppTheme.Spacing.sm {
                            editor.removePointPick(index: index)
                        }
                    }
            )
    }

    private func hint() -> some View {
        Text("Tap to place tracking points · drag to move · click a point to remove · ⏎ to track · Esc to cancel")
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(Color.black.opacity(AppTheme.Opacity.strong), in: .capsule)
    }

    private func confirmButton(count: Int) -> some View {
        Button("Track \(count) point\(count == 1 ? "" : "s")") { editor.commitPointPick() }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .disabled(count == 0)
            .keyboardShortcut(.defaultAction)
    }

    /// Screen point → source-normalized TOP-LEFT (inverse of `screenPoint`: un-rotate about the clip
    /// center, then normalize within the clip's transform rect).
    private func sourcePoint(from screen: CGPoint, clipRect: CGRect, rotationDeg: Double) -> CGPoint {
        let center = CGPoint(x: clipRect.midX, y: clipRect.midY)
        let rad = -rotationDeg * .pi / 180
        let dx = screen.x - center.x, dy = screen.y - center.y
        let ux = center.x + dx * cos(rad) - dy * sin(rad)
        let uy = center.y + dx * sin(rad) + dy * cos(rad)
        guard clipRect.width > 0, clipRect.height > 0 else { return .zero }
        return CGPoint(x: (ux - clipRect.minX) / clipRect.width, y: (uy - clipRect.minY) / clipRect.height)
    }

    /// Source-normalized TOP-LEFT point → screen point (map into the clip rect, then rotate with it).
    private func screenPoint(_ p: CGPoint, clipRect: CGRect, rotationDeg: Double) -> CGPoint {
        let local = CGPoint(x: clipRect.minX + p.x * clipRect.width, y: clipRect.minY + p.y * clipRect.height)
        let center = CGPoint(x: clipRect.midX, y: clipRect.midY)
        let rad = rotationDeg * .pi / 180
        let dx = local.x - center.x, dy = local.y - center.y
        return CGPoint(x: center.x + dx * cos(rad) - dy * sin(rad),
                       y: center.y + dx * sin(rad) + dy * cos(rad))
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
