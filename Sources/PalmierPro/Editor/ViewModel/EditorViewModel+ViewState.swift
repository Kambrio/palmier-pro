import CoreGraphics
import Foundation

extension EditorViewModel {
    /// Snapshot the current editor view state for persistence (last-session resume).
    func currentViewState() -> ProjectViewState {
        var s = ProjectViewState()
        s.playheadFrame = currentFrame
        s.zoomScale = zoomScale
        s.scrollX = timelineScrollX
        s.scrollY = timelineScrollY
        s.selectedClipIds = Array(selectedClipIds)
        s.selectedMediaAssetIds = Array(selectedMediaAssetIds)
        return s
    }

    /// Restore a saved view state on project open. Clamps the playhead, drops selection ids that no
    /// longer exist, and defers the scroll restore to TimelineContainerView (content must be sized
    /// at the restored zoom first). Call after the timeline and media assets are loaded.
    func applyViewState(_ s: ProjectViewState) {
        let total = max(0, timeline.totalFrames)
        currentFrame = max(0, min(s.playheadFrame, total))
        if let z = s.zoomScale, z > 0 {
            zoomScale = min(Zoom.max, max(minZoomScale, z))
        }
        let clipIds = Set(timeline.tracks.flatMap { $0.clips.map(\.id) })
        selectedClipIds = Set(s.selectedClipIds).intersection(clipIds)
        let assetIds = Set(mediaAssets.map(\.id))
        selectedMediaAssetIds = Set(s.selectedMediaAssetIds).intersection(assetIds)
        if s.scrollX > 0 || s.scrollY > 0 {
            pendingTimelineScroll = CGPoint(x: s.scrollX, y: s.scrollY)
        }
    }
}
