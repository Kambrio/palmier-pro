import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

/// The interactive point-track pick session: committing writes the points seed onto the clip
/// (engine = .points) and clears the session; add/remove mutate the session; commit with no points
/// is a no-op; cancel just clears it.
@Suite("EditorViewModel — point picker")
@MainActor
struct PointPickerTests {

    private func makeEditor() -> EditorViewModel {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "v", start: 0, duration: 30)]),
        ])
        editor.selectedClipIds = ["v"]
        return editor
    }

    @Test func commitWritesSeedAndClearsSession() {
        let editor = makeEditor()
        editor.pointPick = PointPickSession(clipId: "v", sourceFrame: 8, points: [])
        editor.addPointPick(CGPoint(x: 0.3, y: 0.4))
        editor.addPointPick(CGPoint(x: 0.6, y: 0.5))

        editor.commitPointPick()

        let clip = editor.timeline.tracks.flatMap(\.clips).first { $0.id == "v" }
        #expect(editor.pointPick == nil)
        #expect(clip?.stabilization?.engine == .points)
        #expect(clip?.stabilization?.pointsSeed?.frame == 8)
        #expect(clip?.stabilization?.pointsSeed?.points.count == 2)
        #expect(clip?.stabilization?.pointsSeed?.points.first == CGPoint(x: 0.3, y: 0.4))
    }

    @Test func addMoveRemoveMutateSession() {
        let editor = makeEditor()
        editor.pointPick = PointPickSession(clipId: "v", sourceFrame: 0, points: [])
        editor.addPointPick(CGPoint(x: 0.1, y: 0.1))
        editor.addPointPick(CGPoint(x: 0.9, y: 0.9))
        #expect(editor.pointPick?.points.count == 2)

        editor.movePointPick(index: 0, to: CGPoint(x: 0.5, y: 0.5))
        #expect(editor.pointPick?.points.first == CGPoint(x: 0.5, y: 0.5))

        editor.removePointPick(index: 0)
        #expect(editor.pointPick?.points.count == 1)
        #expect(editor.pointPick?.points.first == CGPoint(x: 0.9, y: 0.9))
    }

    @Test func addClampsToUnitRange() {
        let editor = makeEditor()
        editor.pointPick = PointPickSession(clipId: "v", sourceFrame: 0, points: [])
        editor.addPointPick(CGPoint(x: -0.5, y: 1.7))
        #expect(editor.pointPick?.points.first == CGPoint(x: 0, y: 1))
    }

    @Test func commitWithNoPointsIsNoOp() {
        let editor = makeEditor()
        editor.pointPick = PointPickSession(clipId: "v", sourceFrame: 3, points: [])

        editor.commitPointPick()

        let clip = editor.timeline.tracks.flatMap(\.clips).first { $0.id == "v" }
        #expect(editor.pointPick == nil)
        #expect(clip?.stabilization?.pointsSeed == nil)
    }

    @Test func cancelClearsSessionWithoutSeed() {
        let editor = makeEditor()
        editor.pointPick = PointPickSession(clipId: "v", sourceFrame: 5, points: [CGPoint(x: 0.5, y: 0.5)])

        editor.cancelPointPick()

        let clip = editor.timeline.tracks.flatMap(\.clips).first { $0.id == "v" }
        #expect(editor.pointPick == nil)
        #expect(clip?.stabilization?.pointsSeed == nil)
    }
}
