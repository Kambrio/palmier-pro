import SwiftUI

/// Live preview of Subject Lock: draws the tracked subject's box on the preview at the current
/// frame (offset into the stabilized/cropped display space), so the user can scrub and confirm the
/// lock follows the right thing. Shown only for the selected subject clip when not actively picking.
struct SubjectTrackOverlay: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        if let clip = trackedClip,
           let mark = editor.stabilizationManager.subjectMark(
               for: clip, sourceFrame: editor.sourceFrame(for: clip)) {
            GeometryReader { geo in
                let videoRect = videoContentRect(in: geo.size)
                let xform = clip.transformAt(frame: editor.activeFrame)
                let clipRect = clipFrame(xform, videoRect: videoRect)
                let w = mark.size.width * clipRect.width
                let h = mark.size.height * clipRect.height
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Accent.spotlight, lineWidth: AppTheme.BorderWidth.medium)
                        .frame(width: w, height: h)
                        .position(x: mark.center.x * clipRect.width, y: mark.center.y * clipRect.height)
                }
                .frame(width: clipRect.width, height: clipRect.height)
                .rotationEffect(.degrees(xform.rotation))
                .position(x: clipRect.midX, y: clipRect.midY)
                .allowsHitTesting(false)
            }
        }
    }

    /// The single selected subject clip eligible for the live overlay (timeline tab, not picking).
    private var trackedClip: Clip? {
        guard editor.subjectTrackingPreview, editor.subjectPicker == nil,
              editor.activePreviewTab == .timeline, editor.selectedClipIds.count <= 2 else { return nil }
        let selected = editor.timeline.tracks.flatMap(\.clips)
            .filter { editor.selectedClipIds.contains($0.id) && $0.mediaType == .video }
        guard selected.count == 1, let clip = selected.first,
              clip.stabilization?.engine == .subject, clip.stabilization?.subjectSeed != nil else { return nil }
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
