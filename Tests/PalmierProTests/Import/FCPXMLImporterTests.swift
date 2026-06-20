import Foundation
import Testing
@testable import PalmierPro

@Suite("FCPXMLImporter.build")
struct FCPXMLImporterBuildTests {

    private func parsed(fps: Int = 24) -> ParsedTimeline {
        ParsedTimeline(
            fps: fps, width: 1920, height: 1080,
            assets: [
                "r2": ParsedAsset(id: "r2", name: "A", src: URL(string: "file:///tmp/a.png"), hasVideo: true, hasAudio: false),
                "r3": ParsedAsset(id: "r3", name: "B", src: URL(string: "file:///tmp/b.png"), hasVideo: true, hasAudio: false),
            ],
            tracks: [ParsedTrack(kind: .video, clips: [
                ParsedClip(assetId: "r2", startFrame: 0, durationFrames: 120, sourceInFrames: 0, isGap: false),
                ParsedClip(assetId: "missing", startFrame: 120, durationFrames: 24, sourceInFrames: 0, isGap: false),
                ParsedClip(assetId: "r3", startFrame: 146, durationFrames: 116, sourceInFrames: 12, isGap: false),
            ])],
            skipped: ["title"])
    }

    private let resolver: (ParsedAsset) -> String? = { $0.id == "missing" ? nil : "media-\($0.id)" }

    @Test func replacesEmptyTimelineAndSetsFormat() {
        let (timeline, summary) = FCPXMLImporter.build(
            parsed: parsed(), into: Timeline(), resolveMedia: resolver)
        #expect(timeline.fps == 24)
        #expect(timeline.width == 1920)
        #expect(timeline.tracks.count == 1)
        let clips = timeline.tracks[0].clips
        #expect(clips.count == 2)                 // missing-asset clip skipped
        #expect(clips[0].mediaRef == "media-r2")
        #expect(clips[0].startFrame == 0)
        #expect(clips[0].durationFrames == 120)
        #expect(clips[1].mediaRef == "media-r3")
        #expect(clips[1].startFrame == 146)
        #expect(clips[1].trimStartFrame == 12)
        #expect(summary.clipsAdded == 2)
        #expect(summary.clipsSkipped == 1)
        #expect(summary.tracksAdded == 1)
        #expect(summary.skipped.contains("title"))
    }

    @Test func appendsToNonEmptyTimelineConvertingFps() {
        var existing = Timeline()
        existing.fps = 48
        existing.tracks = [Track(type: .video, clips: [
            Clip(mediaRef: "x", startFrame: 0, durationFrames: 10)])]
        let (timeline, _) = FCPXMLImporter.build(
            parsed: parsed(fps: 24), into: existing, resolveMedia: resolver)
        #expect(timeline.tracks.count == 2)        // existing kept + imported appended
        #expect(timeline.fps == 48)                // project fps preserved on append
        #expect(timeline.tracks[1].clips[0].durationFrames == 240)  // 120 @24 -> 240 @48
    }
}
