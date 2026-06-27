import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

/// The interactive subject-picker session: committing a pick writes the seed onto the clip
/// (engine = .subject) and clears the session; cancel just clears it.
@Suite("EditorViewModel — subject picker")
@MainActor
struct SubjectPickerTests {

    private func makeEditor() -> EditorViewModel {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "v", start: 0, duration: 30)]),
        ])
        return editor
    }

    @Test func commitWritesSeedAndClearsSession() {
        let editor = makeEditor()
        let box = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        editor.subjectPicker = SubjectPickerSession(
            clipId: "v", sourceFrame: 12,
            objects: [DetectedObject(id: 0, label: "person", confidence: 0.97, box: box)])

        editor.commitSubjectPick(object: editor.subjectPicker!.objects[0])

        let clip = editor.timeline.tracks.flatMap(\.clips).first { $0.id == "v" }
        #expect(editor.subjectPicker == nil)
        #expect(clip?.stabilization?.engine == .subject)
        #expect(clip?.stabilization?.subjectSeed?.frame == 12)
        #expect(clip?.stabilization?.subjectSeed?.label == "person")
        #expect(clip?.stabilization?.subjectSeed?.box == box)
    }

    @Test func cancelClearsSessionWithoutSeed() {
        let editor = makeEditor()
        editor.subjectPicker = SubjectPickerSession(
            clipId: "v", sourceFrame: 5,
            objects: [DetectedObject(id: 0, label: "dog", confidence: 0.5, box: .zero)])

        editor.cancelSubjectPick()

        let clip = editor.timeline.tracks.flatMap(\.clips).first { $0.id == "v" }
        #expect(editor.subjectPicker == nil)
        #expect(clip?.stabilization?.subjectSeed == nil)
    }
}
