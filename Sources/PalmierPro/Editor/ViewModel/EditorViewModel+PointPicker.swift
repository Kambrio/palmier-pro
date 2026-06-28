import CoreGraphics
import Foundation

/// An in-progress Point Track pick: the user-placed tracking points (normalized TOP-LEFT) on a
/// chosen source frame of a clip.
struct PointPickSession: Equatable {
    var clipId: String
    var sourceFrame: Int
    var points: [CGPoint]
}

extension EditorViewModel {
    /// The pick session valid for the preview: timeline tab, its clip still selected, and still on
    /// the points engine. A stale session renders to nothing and is ignored on commit.
    var activePointPick: PointPickSession? {
        guard let s = pointPick, activePreviewTab == .timeline, selectedClipIds.contains(s.clipId),
              let clip = timeline.tracks.flatMap(\.clips).first(where: { $0.id == s.clipId }),
              clip.stabilization?.engine == .points else { return nil }
        return s
    }

    /// Enter point-placing mode for `clip`. No detection needed — the live preview already shows the
    /// frame; we only seed the session (with any existing points when editing) and pause playback.
    func beginPointPick(clip: Clip) {
        guard mediaResolver.resolveURL(for: clip.mediaRef) != nil else {
            mediaPanelToast = "Point Track needs the clip's source file — it appears to be offline."
            return
        }
        if isPlaying { pause() }
        // Re-anchor at the CURRENT playhead frame so tracking recomputes forward/backward from here.
        // Pre-load any existing points so they can be nudged onto the object at this frame.
        let frame = sourceFrame(for: clip)
        pointPick = PointPickSession(
            clipId: clip.id, sourceFrame: frame, points: clip.stabilization?.pointsSeed?.points ?? [])
        videoEngine?.refreshVisuals()   // show the clip RAW so points land on real source pixels
    }

    /// Add a tracking point (normalized TOP-LEFT), clamped to the frame.
    func addPointPick(_ p: CGPoint) {
        guard var s = pointPick else { return }
        s.points.append(clampUnit(p))
        pointPick = s
    }

    /// Move the point at `index` to a new normalized TOP-LEFT position.
    func movePointPick(index: Int, to p: CGPoint) {
        guard var s = pointPick, index >= 0, index < s.points.count else { return }
        s.points[index] = clampUnit(p)
        pointPick = s
    }

    func removePointPick(index: Int) {
        guard var s = pointPick, index >= 0, index < s.points.count else { return }
        s.points.remove(at: index)
        pointPick = s
    }

    /// Commit the placed points as the clip's points seed and start tracking (needs ≥ 1 point).
    func commitPointPick() {
        guard let session = pointPick, !session.points.isEmpty,
              selectedClipIds.contains(session.clipId),
              let clip = timeline.tracks.flatMap(\.clips).first(where: { $0.id == session.clipId }) else {
            pointPick = nil
            return
        }
        let seed = PointsSeed(frame: session.sourceFrame, points: session.points)
        mutateClips(ids: [clip.id], actionName: "Track Points") { c in
            var s = c.stabilization ?? Stabilization()
            s.engine = .points
            s.pointsSeed = seed
            c.stabilization = s
        }
        pointPick = nil
        stabilizationManager.invalidateCache()
        videoEngine?.refreshVisuals()
        if let url = mediaResolver.resolveURL(for: clip.mediaRef) {
            stabilizationManager.enqueuePointsTrack(assetId: clip.mediaRef, url: url, seed: seed)
        }
    }

    func cancelPointPick() {
        pointPick = nil
        videoEngine?.refreshVisuals()   // restore the stabilized preview
    }

    private func clampUnit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }
}
