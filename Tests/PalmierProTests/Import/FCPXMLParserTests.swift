import Foundation
import Testing
@testable import PalmierPro

@Suite("FCPXMLParser")
struct FCPXMLParserTests {

    // Astronaut-style subset: 1080p24 format, 2 assets, a spine with 2 videos + a gap,
    // plus one unsupported <title> that must be skipped (not crash).
    private let fixture = """
    <?xml version='1.0' encoding='UTF-8'?>
    <!DOCTYPE fcpxml>
    <fcpxml version="1.10">
      <resources>
        <format id="r1" name="FFVideoFormat1080p24" frameDuration="1/24s" width="1920" height="1080" />
        <asset id="r2" name="shotA" start="0s" duration="5s" hasVideo="1" hasAudio="0" format="r1">
          <media-rep kind="original-media" src="file:///tmp/a%20b/shotA.png" />
        </asset>
        <asset id="r3" name="shotB" start="0s" duration="116/24s" hasVideo="1" hasAudio="0" format="r1">
          <media-rep kind="original-media" src="file:///tmp/shotB.png" />
        </asset>
      </resources>
      <library>
        <event name="E">
          <project name="P">
            <sequence format="r1" duration="240s" tcStart="0s" tcFormat="NDF">
              <spine>
                <video ref="r2" name="shotA" offset="0s" duration="5s" start="0s" />
                <gap offset="5s" duration="1s" />
                <video ref="r3" name="shotB" offset="146/24s" duration="116/24s" start="12/24s" />
                <title ref="r9" offset="0s" duration="1s" />
              </spine>
            </sequence>
          </project>
        </event>
      </library>
    </fcpxml>
    """

    private func parse() throws -> ParsedTimeline {
        try FCPXMLParser.parse(data: Data(fixture.utf8))
    }

    @Test func readsFormatFpsAndSize() throws {
        let t = try parse()
        #expect(t.fps == 24)
        #expect(t.width == 1920)
        #expect(t.height == 1080)
    }

    @Test func readsAssetsWithDecodedFileURLs() throws {
        let t = try parse()
        #expect(t.assets["r2"]?.name == "shotA")
        #expect(t.assets["r2"]?.src?.path == "/tmp/a b/shotA.png")   // percent-decoded
        #expect(t.assets["r2"]?.hasVideo == true)
        #expect(t.assets["r2"]?.hasAudio == false)
    }

    @Test func buildsSpineTrackWithClipsAndGap() throws {
        let t = try parse()
        #expect(t.tracks.count == 1)
        let clips = t.tracks[0].clips
        #expect(clips.count == 3)            // 2 videos + 1 gap (title skipped)
        #expect(clips[0].assetId == "r2")
        #expect(clips[0].startFrame == 0)
        #expect(clips[0].durationFrames == 120)
        #expect(clips[1].isGap == true)
        #expect(clips[2].assetId == "r3")
        #expect(clips[2].startFrame == 146)
        #expect(clips[2].durationFrames == 116)
        #expect(clips[2].sourceInFrames == 12)
    }

    @Test func recordsUnsupportedElementsAsSkipped() throws {
        let t = try parse()
        #expect(t.skipped.contains("title"))
    }

    @Test func throwsOnNonFCPXML() {
        #expect(throws: (any Error).self) {
            _ = try FCPXMLParser.parse(data: Data("<other/>".utf8))
        }
    }
}
