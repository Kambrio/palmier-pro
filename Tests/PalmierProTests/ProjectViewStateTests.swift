import Testing
import Foundation
@testable import PalmierPro

struct ProjectViewStateModelTests {
    @Test func roundTripsAndToleratesMissingFields() throws {
        var s = ProjectViewState()
        s.playheadFrame = 1234
        s.zoomScale = 8.5
        s.scrollX = 400; s.scrollY = 20
        s.selectedClipIds = ["clip-a"]
        s.selectedMediaAssetIds = ["asset-1", "asset-2"]

        let decoded = try JSONDecoder().decode(ProjectViewState.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)

        // Minimal payload still decodes with defaults.
        let minimal = try JSONDecoder().decode(ProjectViewState.self, from: Data(#"{"playheadFrame":7}"#.utf8))
        #expect(minimal.playheadFrame == 7)
        #expect(minimal.zoomScale == nil)
        #expect(minimal.selectedClipIds.isEmpty)
    }

    @Test func isDefaultDetectsEmpty() {
        #expect(ProjectViewState().isDefault)
        var s = ProjectViewState(); s.playheadFrame = 1
        #expect(!s.isDefault)
    }
}

@MainActor
struct ProjectViewStateApplyTests {
    @Test func applyClampsPlayheadAndFiltersStaleSelection() {
        let editor = EditorViewModel()
        // Two tracks/clips so we have real ids + a known total length.
        var track = Track(type: .video)
        let clip = Clip(mediaRef: "m1", startFrame: 0, durationFrames: 100)
        track.clips = [clip]
        editor.timeline.tracks = [track]
        editor.mediaAssets = [MediaAsset(url: URL(fileURLWithPath: "/tmp/m1.mov"), type: .video, name: "m1")]

        var s = ProjectViewState()
        s.playheadFrame = 999_999            // beyond timeline → clamp to totalFrames
        s.zoomScale = 12
        s.selectedClipIds = [clip.id, "gone-clip"]   // one valid, one stale
        s.selectedMediaAssetIds = ["nope"]           // stale (asset id is random UUID)
        s.scrollX = 250; s.scrollY = 0

        editor.applyViewState(s)

        #expect(editor.currentFrame == editor.timeline.totalFrames)
        #expect(editor.currentFrame <= editor.timeline.totalFrames)
        #expect(editor.zoomScale == 12)
        #expect(editor.selectedClipIds == [clip.id])      // stale id dropped
        #expect(editor.selectedMediaAssetIds.isEmpty)     // stale asset dropped
        #expect(editor.pendingTimelineScroll?.x == 250)   // deferred to the view layer
    }

    @Test func currentViewStateCapturesEditorState() {
        let editor = EditorViewModel()
        editor.currentFrame = 42
        editor.zoomScale = 6
        editor.timelineScrollX = 130
        editor.selectedClipIds = ["c1"]
        editor.selectedMediaAssetIds = ["a1"]

        let s = editor.currentViewState()
        #expect(s.playheadFrame == 42)
        #expect(s.zoomScale == 6)
        #expect(s.scrollX == 130)
        #expect(s.selectedClipIds == ["c1"])
        #expect(s.selectedMediaAssetIds == ["a1"])
    }
}
