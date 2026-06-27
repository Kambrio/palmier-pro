import SwiftUI

/// Live preview of Point Track: draws the tracked points on the preview at the current frame (offset
/// into the stabilized/cropped display space), so the user can scrub and confirm the lock follows the
/// right object. Shown only for the selected points clip with a seed when not actively picking.
struct PointTrackOverlay: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        if let clip = trackedClip,
           let marks = editor.stabilizationManager.pointMarks(
               for: clip, sourceFrame: editor.sourceFrame(for: clip)) {
            GeometryReader { geo in
                let videoRect = videoContentRect(in: geo.size)
                let xform = clip.transformAt(frame: editor.activeFrame)
                let clipRect = clipFrame(xform, videoRect: videoRect)
                ZStack {
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, p in
                        Circle()
                            .fill(AppTheme.Accent.spotlight)
                            .overlay(Circle().strokeBorder(.white, lineWidth: AppTheme.BorderWidth.thin))
                            .frame(width: AppTheme.Spacing.md, height: AppTheme.Spacing.md)
                            .position(x: p.x * clipRect.width, y: p.y * clipRect.height)
                    }
                }
                .frame(width: clipRect.width, height: clipRect.height)
                .rotationEffect(.degrees(xform.rotation))
                .position(x: clipRect.midX, y: clipRect.midY)
                .allowsHitTesting(false)
            }
        }
    }

    /// The single selected points clip eligible for the live overlay (timeline tab, not picking).
    private var trackedClip: Clip? {
        guard editor.subjectTrackingPreview, editor.pointPick == nil, editor.subjectPicker == nil,
              editor.activePreviewTab == .timeline, editor.selectedClipIds.count <= 2 else { return nil }
        let selected = editor.timeline.tracks.flatMap(\.clips)
            .filter { editor.selectedClipIds.contains($0.id) && $0.mediaType == .video }
        guard selected.count == 1, let clip = selected.first,
              clip.stabilization?.engine == .points, clip.stabilization?.pointsSeed != nil else { return nil }
        return clip
    }

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
