# FCPXML Timeline Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import an FCPXML file into the open Palmier project — parse it to a Palmier `Timeline`, import the referenced media, and apply it — via an `import_timeline` MCP tool and a File → Import… menu item.

**Architecture:** A pure parsing core (`FCPTime` + `FCPXMLParser` → a `ParsedTimeline` value, no app state) feeds an app-facing `FCPXMLImporter` that resolves media (existing `addMediaAsset`, with iCloud materialization) and builds/applies tracks+clips. Two thin surfaces (MCP tool, File menu) call the importer. Unsupported FCPXML constructs are skipped and reported, never fatal.

**Tech Stack:** Swift 6.2, `Foundation.XMLDocument`, Swift Testing (`import Testing`). Spec: `docs/superpowers/specs/2026-06-20-fcpxml-import-design.md`.

---

## File structure

**New (`Sources/PalmierPro/Import/`):**
- `FCPTime.swift` — parse FCPXML rational time → seconds → frames (pure).
- `ParsedTimeline.swift` — intermediate value types (`ParsedTimeline`/`ParsedAsset`/`ParsedClip`/`ParsedTrack` + enums).
- `FCPXMLParser.swift` — `XMLDocument` → `ParsedTimeline` (pure).
- `FCPXMLImporter.swift` — resolve media + build Palmier `Timeline` + apply to editor; returns `ImportSummary`.

**New tool:**
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+ImportTimeline.swift` — `import_timeline` implementation.

**Modify:**
- `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift` — add `ToolName.importTimeline` + `AgentTool` entry.
- `Sources/PalmierPro/Agent/Tools/ToolExecutor.swift` — dispatch `case .importTimeline`.
- `Sources/PalmierPro/App/MainMenu.swift` — File → Import… item.

**Tests (`Tests/PalmierProTests/Import/`):**
- `FCPTimeTests.swift`, `FCPXMLParserTests.swift`, `FCPXMLImporterTests.swift`.

Commands: `swift build`; `swift test --filter <Suite>`.

---

## Task 1: FCPTime

**Files:**
- Create: `Sources/PalmierPro/Import/FCPTime.swift`
- Test: `Tests/PalmierProTests/Import/FCPTimeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Import/FCPTimeTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("FCPTime")
struct FCPTimeTests {
    @Test func parsesWholeSeconds() {
        #expect(FCPTime.seconds("5s") == 5.0)
        #expect(FCPTime.seconds("0s") == 0.0)
    }

    @Test func parsesRationalSeconds() {
        #expect(FCPTime.seconds("116/24s") == 116.0 / 24.0)
        #expect(FCPTime.seconds("30000/1001s") == 30000.0 / 1001.0)
    }

    @Test func toleratesMissingSuffixAndWhitespace() {
        #expect(FCPTime.seconds(" 3 ") == 3.0)
    }

    @Test func returnsNilOnGarbage() {
        #expect(FCPTime.seconds("abc") == nil)
        #expect(FCPTime.seconds("1/0s") == nil)   // divide by zero
        #expect(FCPTime.seconds("") == nil)
    }

    @Test func convertsToFramesRounded() {
        #expect(FCPTime.frames("116/24s", fps: 24) == 116)   // 116/24 * 24
        #expect(FCPTime.frames("5s", fps: 24) == 120)
        #expect(FCPTime.frames("236/24s", fps: 24) == 236)
        #expect(FCPTime.frames("garbage", fps: 24) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FCPTime`
Expected: FAIL — `FCPTime` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PalmierPro/Import/FCPTime.swift
import Foundation

/// Parses FCPXML rational time values ("5s", "116/24s", "0s") to seconds and frames.
enum FCPTime {
    /// Seconds for a raw FCPXML time string, or nil if unparseable.
    static func seconds(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        if let slash = s.firstIndex(of: "/") {
            let numStr = String(s[s.startIndex..<slash])
            let denStr = String(s[s.index(after: slash)...])
            guard let num = Double(numStr), let den = Double(denStr), den != 0 else { return nil }
            return num / den
        }
        return Double(s)
    }

    /// Frame count at `fps`, rounded, or nil if the value is unparseable.
    static func frames(_ raw: String, fps: Int) -> Int? {
        guard let sec = seconds(raw) else { return nil }
        return Int((sec * Double(fps)).rounded())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FCPTime`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Import/FCPTime.swift Tests/PalmierProTests/Import/FCPTimeTests.swift
git commit -m "feat: add FCPTime parser for FCPXML rational time

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: ParsedTimeline value types

**Files:**
- Create: `Sources/PalmierPro/Import/ParsedTimeline.swift`

No test (pure data types; exercised by Tasks 3–4). Verification = builds.

- [ ] **Step 1: Write the types**

```swift
// Sources/PalmierPro/Import/ParsedTimeline.swift
import Foundation

/// Intermediate, app-state-free model produced by FCPXMLParser and consumed by
/// FCPXMLImporter. All frame counts are in `fps` frames.
struct ParsedTimeline: Equatable {
    var fps: Int
    var width: Int
    var height: Int
    var assets: [String: ParsedAsset]   // id → asset
    var tracks: [ParsedTrack]
    var skipped: [String]               // unsupported elements, for the import summary
}

struct ParsedAsset: Equatable {
    var id: String
    var name: String
    var src: URL?
    var hasVideo: Bool
    var hasAudio: Bool
}

enum ParsedTrackKind: Equatable { case video, audio }

struct ParsedTrack: Equatable {
    var kind: ParsedTrackKind
    var clips: [ParsedClip]
}

/// A placed clip. `assetId` is empty for a gap.
struct ParsedClip: Equatable {
    var assetId: String
    var startFrame: Int
    var durationFrames: Int
    var sourceInFrames: Int
    var isGap: Bool
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Import/ParsedTimeline.swift
git commit -m "feat: add ParsedTimeline intermediate model for FCPXML import

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: FCPXMLParser

**Files:**
- Create: `Sources/PalmierPro/Import/FCPXMLParser.swift`
- Test: `Tests/PalmierProTests/Import/FCPXMLParserTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Import/FCPXMLParserTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("FCPXMLParser")
struct FCPXMLParserTests {

    // Astronaut-style subset: 1080p24 format, 3 assets, a spine with 2 videos + a gap,
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
        // 2 videos + 1 gap (title skipped)
        #expect(clips.count == 3)
        #expect(clips[0].assetId == "r2")
        #expect(clips[0].startFrame == 0)
        #expect(clips[0].durationFrames == 120)        // 5s @24
        #expect(clips[1].isGap == true)                 // gap @ 120, len 24
        #expect(clips[2].assetId == "r3")
        #expect(clips[2].startFrame == 146)             // 146/24s @24
        #expect(clips[2].durationFrames == 116)
        #expect(clips[2].sourceInFrames == 12)          // start=12/24s @24
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FCPXMLParser`
Expected: FAIL — `FCPXMLParser` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PalmierPro/Import/FCPXMLParser.swift
import Foundation

enum FCPXMLParseError: LocalizedError {
    case unreadable(String)
    case notFCPXML
    case noSequence

    var errorDescription: String? {
        switch self {
        case .unreadable(let m): return "Could not read FCPXML: \(m)"
        case .notFCPXML: return "Not an FCPXML document (missing <fcpxml> root)."
        case .noSequence: return "No <sequence>/<spine> found in the FCPXML."
        }
    }
}

/// Parses an FCPXML document into a `ParsedTimeline`. Pure — no app state.
enum FCPXMLParser {
    /// Spine elements we turn into clips; everything else is recorded as skipped.
    private static let clipElementNames: Set<String> = ["video", "asset-clip", "clip"]

    static func parse(url: URL) throws -> ParsedTimeline {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw FCPXMLParseError.unreadable(error.localizedDescription) }
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> ParsedTimeline {
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data) }
        catch { throw FCPXMLParseError.unreadable(error.localizedDescription) }

        guard let root = doc.rootElement(), root.name == "fcpxml" else {
            throw FCPXMLParseError.notFCPXML
        }

        let resources = root.elements(forName: "resources").first
        let (fps, width, height) = parseFormat(resources)
        let assets = parseAssets(resources)

        guard let spine = firstDescendant(named: "spine", in: root) else {
            throw FCPXMLParseError.noSequence
        }

        var skipped: [String] = []
        var clips: [ParsedClip] = []
        for child in (spine.children ?? []) {
            guard let el = child as? XMLElement, let name = el.name else { continue }
            if name == "gap" {
                clips.append(ParsedClip(
                    assetId: "",
                    startFrame: FCPTime.frames(attr(el, "offset") ?? "0s", fps: fps) ?? 0,
                    durationFrames: FCPTime.frames(attr(el, "duration") ?? "0s", fps: fps) ?? 0,
                    sourceInFrames: 0, isGap: true))
            } else if clipElementNames.contains(name) {
                clips.append(ParsedClip(
                    assetId: attr(el, "ref") ?? "",
                    startFrame: FCPTime.frames(attr(el, "offset") ?? "0s", fps: fps) ?? 0,
                    durationFrames: FCPTime.frames(attr(el, "duration") ?? "0s", fps: fps) ?? 0,
                    sourceInFrames: FCPTime.frames(attr(el, "start") ?? "0s", fps: fps) ?? 0,
                    isGap: false))
            } else {
                skipped.append(name)
            }
        }

        // Track kind from the first non-gap clip's asset (default video).
        let firstAsset = clips.first(where: { !$0.isGap }).flatMap { assets[$0.assetId] }
        let kind: ParsedTrackKind = (firstAsset?.hasAudio == true && firstAsset?.hasVideo == false) ? .audio : .video
        let tracks = clips.isEmpty ? [] : [ParsedTrack(kind: kind, clips: clips)]

        return ParsedTimeline(fps: fps, width: width, height: height,
                              assets: assets, tracks: tracks, skipped: skipped)
    }

    // MARK: - Helpers

    private static func attr(_ el: XMLElement, _ name: String) -> String? {
        el.attribute(forName: name)?.stringValue
    }

    private static func parseFormat(_ resources: XMLElement?) -> (fps: Int, width: Int, height: Int) {
        guard let format = resources?.elements(forName: "format").first else { return (30, 1920, 1080) }
        let fps: Int
        if let fd = attr(format, "frameDuration"), let sec = FCPTime.seconds(fd), sec > 0 {
            fps = Int((1.0 / sec).rounded())
        } else { fps = 30 }
        let width = attr(format, "width").flatMap { Int($0) } ?? 1920
        let height = attr(format, "height").flatMap { Int($0) } ?? 1080
        return (fps, width, height)
    }

    private static func parseAssets(_ resources: XMLElement?) -> [String: ParsedAsset] {
        var out: [String: ParsedAsset] = [:]
        for el in resources?.elements(forName: "asset") ?? [] {
            guard let id = attr(el, "id") else { continue }
            let mediaRep = el.elements(forName: "media-rep").first
            let src = mediaRep.flatMap { attr($0, "src") }.flatMap { URL(string: $0) }
            out[id] = ParsedAsset(
                id: id,
                name: attr(el, "name") ?? id,
                src: src,
                hasVideo: attr(el, "hasVideo") == "1",
                hasAudio: attr(el, "hasAudio") == "1")
        }
        return out
    }

    /// Depth-first search for the first element with the given name.
    private static func firstDescendant(named name: String, in element: XMLElement) -> XMLElement? {
        for child in (element.children ?? []) {
            guard let el = child as? XMLElement else { continue }
            if el.name == name { return el }
            if let found = firstDescendant(named: name, in: el) { return found }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FCPXMLParser`
Expected: PASS (5 tests). Note `URL(string:)` percent-decodes via `.path`, so `/tmp/a b/shotA.png` matches.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Import/FCPXMLParser.swift Tests/PalmierProTests/Import/FCPXMLParserTests.swift
git commit -m "feat: add FCPXMLParser (XMLDocument -> ParsedTimeline)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: FCPXMLImporter build (tracks/clips, append/replace)

**Files:**
- Create: `Sources/PalmierPro/Import/FCPXMLImporter.swift`
- Test: `Tests/PalmierProTests/Import/FCPXMLImporterTests.swift`

The build step is the testable core: it takes a `ParsedTimeline`, an injected media resolver (`ParsedAsset -> mediaRef String?`), and the current `Timeline`, and returns the new `Timeline` + an `ImportSummary`. Pure function over values — no `EditorViewModel`, no disk.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Import/FCPXMLImporterTests.swift
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

    // Resolver maps known asset ids to a fake media id; "missing" returns nil.
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
        // existing track kept, imported track appended
        #expect(timeline.tracks.count == 2)
        #expect(timeline.fps == 48)               // project fps preserved on append
        // 120 frames @24 -> 240 frames @48
        #expect(timeline.tracks[1].clips[0].durationFrames == 240)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "FCPXMLImporter.build"`
Expected: FAIL — `FCPXMLImporter` not defined.

- [ ] **Step 3: Write the build implementation**

```swift
// Sources/PalmierPro/Import/FCPXMLImporter.swift
import Foundation

struct ImportSummary: Sendable {
    var tracksAdded = 0
    var clipsAdded = 0
    var mediaImported = 0
    var clipsSkipped = 0
    var skipped: [String] = []

    var text: String {
        var s = "Imported \(clipsAdded) clip(s) across \(tracksAdded) track(s); \(mediaImported) media file(s)."
        if clipsSkipped > 0 { s += " Skipped \(clipsSkipped) clip(s) with unresolved media." }
        if !skipped.isEmpty { s += " Unsupported (ignored): \(Set(skipped).sorted().joined(separator: ", "))." }
        return s
    }
}

enum FCPXMLImporter {
    /// Pure build: turns a ParsedTimeline into a new Timeline. `resolveMedia` returns the
    /// imported asset id (mediaRef) for a ParsedAsset, or nil if it couldn't be resolved.
    /// Replaces `current` if it has no clips, otherwise appends the imported tracks.
    static func build(
        parsed: ParsedTimeline,
        into current: Timeline,
        resolveMedia: (ParsedAsset) -> String?
    ) -> (Timeline, ImportSummary) {
        let hasExisting = current.tracks.contains { !$0.clips.isEmpty }
        let targetFps = hasExisting ? current.fps : parsed.fps

        func conv(_ frames: Int) -> Int {
            guard parsed.fps != targetFps, parsed.fps > 0 else { return frames }
            return Int((Double(frames) / Double(parsed.fps) * Double(targetFps)).rounded())
        }

        var summary = ImportSummary(skipped: parsed.skipped)
        var newTracks: [Track] = []

        for pTrack in parsed.tracks {
            var clips: [Clip] = []
            for pClip in pTrack.clips where !pClip.isGap {
                guard let asset = parsed.assets[pClip.assetId],
                      let mediaRef = resolveMedia(asset) else {
                    summary.clipsSkipped += 1
                    continue
                }
                let type = clipType(for: asset, kind: pTrack.kind)
                clips.append(Clip(
                    mediaRef: mediaRef,
                    mediaType: type,
                    sourceClipType: type,
                    startFrame: conv(pClip.startFrame),
                    durationFrames: max(1, conv(pClip.durationFrames)),
                    trimStartFrame: conv(pClip.sourceInFrames)))
            }
            guard !clips.isEmpty else { continue }
            newTracks.append(Track(type: pTrack.kind == .audio ? .audio : .video, clips: clips))
            summary.clipsAdded += clips.count
        }
        summary.tracksAdded = newTracks.count

        var result = current
        if hasExisting {
            result.tracks.append(contentsOf: newTracks)
        } else {
            result = Timeline(fps: parsed.fps, width: parsed.width, height: parsed.height,
                              settingsConfigured: true, tracks: newTracks)
        }
        return (result, summary)
    }

    private static func clipType(for asset: ParsedAsset, kind: ParsedTrackKind) -> ClipType {
        if kind == .audio { return .audio }
        if let ext = asset.src?.pathExtension.lowercased(),
           ClipType(fileExtension: ext) == .image { return .image }
        return .video
    }
}
```

Note: confirm `Timeline`'s memberwise init accepts `(fps:width:height:settingsConfigured:tracks:)` — it has these stored properties with defaults, so the call compiles. If the field order differs, adjust to named args (they're all labeled).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "FCPXMLImporter.build"`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Import/FCPXMLImporter.swift Tests/PalmierProTests/Import/FCPXMLImporterTests.swift
git commit -m "feat: add FCPXMLImporter build (tracks/clips, append/replace, fps convert)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: FCPXMLImporter.importFile (parse + real media resolution)

**Files:**
- Modify: `Sources/PalmierPro/Import/FCPXMLImporter.swift`

Adds the `@MainActor` glue that parses a URL, resolves each asset to a real imported `MediaAsset` (existing `editor.addMediaAsset(from:)`, materializing iCloud placeholders), runs `build`, and applies the result to the editor. No unit test (touches disk + editor); verified manually and by the build tests above.

- [ ] **Step 1: Append the import glue to `FCPXMLImporter`**

```swift
extension FCPXMLImporter {
    /// Parses `url`, imports referenced media into `editor`, builds + applies the timeline.
    @MainActor
    static func importFile(at url: URL, into editor: EditorViewModel) throws -> ImportSummary {
        let parsed = try FCPXMLParser.parse(url: url)

        // Resolve each asset id -> imported MediaAsset id (referenced in place).
        var resolved: [String: String] = [:]
        var imported = 0
        for (id, asset) in parsed.assets {
            guard let src = asset.src, src.isFileURL else { continue }
            materializeIfNeeded(src)
            guard FileManager.default.fileExists(atPath: src.path),
                  let mediaAsset = editor.addMediaAsset(from: src) else { continue }
            resolved[id] = mediaAsset.id
            imported += 1
        }

        var (timeline, summary) = build(parsed: parsed, into: editor.timeline) { asset in
            resolved[asset.id]
        }
        summary.mediaImported = imported
        editor.timeline = timeline
        return summary
    }

    /// Triggers iCloud download for a not-yet-downloaded file and waits briefly.
    @MainActor
    private static func materializeIfNeeded(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true,
              values?.ubiquitousItemDownloadingStatus != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        // Bounded wait for the placeholder to materialize.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path),
               (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                   .ubiquitousItemDownloadingStatus == .current { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly. (Confirm `editor.addMediaAsset(from:)` returns `MediaAsset?` and `MediaAsset.id` is `String` — both verified in `EditorViewModel+MediaLibrary.swift`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Import/FCPXMLImporter.swift
git commit -m "feat: add FCPXMLImporter.importFile (media resolution + iCloud materialize)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: import_timeline MCP tool

**Files:**
- Create: `Sources/PalmierPro/Agent/Tools/ToolExecutor+ImportTimeline.swift`
- Modify: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor.swift`

- [ ] **Step 1: Add the ToolName case**

In `ToolDefinitions.swift`, in the `enum ToolName`, add after `case importMedia = "import_media"`:

```swift
    case importTimeline = "import_timeline"
```

- [ ] **Step 2: Add the AgentTool definition**

In `ToolDefinitions.swift`, in the `all` array (next to the `importMedia` `AgentTool`), add:

```swift
        AgentTool(
            name: .importTimeline,
            description: "Imports an FCPXML timeline file from a local path into the current project. Parses the sequence and its referenced media (images/video/audio), imports the media, and builds the timeline — replacing the current timeline if it is empty, otherwise appending the imported clips as new tracks. Only FCPXML (.fcpxml) is supported; unsupported constructs (transitions, titles, effects, keyframes) are skipped and reported. Returns a summary of what was imported.",
            inputSchema: objectSchema(
                properties: [
                    "path": ["type": "string", "description": "Absolute local path to a .fcpxml file. The file (and the media it references) must be readable by the Palmier process."],
                ],
                required: ["path"]
            )
        ),
```

- [ ] **Step 3: Dispatch in `execute`**

In `ToolExecutor.swift`, in the `switch tool` inside `execute`, add next to `case .importMedia`:

```swift
            case .importTimeline: return try importTimeline(editor, args)
```

- [ ] **Step 4: Write the tool implementation**

```swift
// Sources/PalmierPro/Agent/Tools/ToolExecutor+ImportTimeline.swift
import Foundation

extension ToolExecutor {
    private static let importTimelineAllowedKeys: Set<String> = ["path"]

    func importTimeline(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.importTimelineAllowedKeys, path: "import_timeline")
        guard let path = args.string("path"), !path.isEmpty else {
            throw ToolError("Missing required 'path'")
        }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "fcpxml" else {
            throw ToolError("Only .fcpxml files are supported (got '.\(url.pathExtension)')")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("File not found: \(path)")
        }
        do {
            let summary = try FCPXMLImporter.importFile(at: url, into: editor)
            guard summary.clipsAdded > 0 else {
                return .error("No importable clips found in \(url.lastPathComponent).")
            }
            return .ok(summary.text + " See get_timeline / get_media for the result.")
        } catch {
            return .error("FCPXML import failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds cleanly. (`validateUnknownKeys` and `args.string(_:)` already exist in the ToolExecutor extensions.)

- [ ] **Step 6: Run the existing tool tests for regressions**

Run: `swift test --filter ToolExecutor`
Expected: PASS (no regressions from the new case).

- [ ] **Step 7: Commit**

```bash
git add Sources/PalmierPro/Agent/Tools/ToolExecutor+ImportTimeline.swift Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift Sources/PalmierPro/Agent/Tools/ToolExecutor.swift
git commit -m "feat: add import_timeline MCP tool for FCPXML import

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: File → Import… menu

The File menu dispatches through the responder chain via the `@objc protocol EditorActions`
(in `MainMenu.swift`); `EditorWindowController` conforms to it and holds `editorViewModel`.
Follow that exact pattern — add a protocol method, a menu item, and the implementation on
`EditorWindowController`.

**Files:**
- Modify: `Sources/PalmierPro/App/MainMenu.swift`
- Modify: `Sources/PalmierPro/Editor/EditorWindowController.swift`

- [ ] **Step 1: Add the protocol method**

In `MainMenu.swift`, in `@MainActor @objc protocol EditorActions`, add next to `func importMedia(_ sender: Any?)`:

```swift
    func importTimeline(_ sender: Any?)
```

- [ ] **Step 2: Add the File menu item**

In `MainMenu.swift`, in `fileMenu()`, after the existing `importItem` (Import Media…) block and before its trailing `.separator()`, add:

```swift
        let importTimelineItem = NSMenuItem(title: "Import Timeline…", action: #selector(EditorActions.importTimeline(_:)), keyEquivalent: "")
        menu.addItem(importTimelineItem)
```

- [ ] **Step 3: Implement the action on EditorWindowController**

In `EditorWindowController.swift`, next to the existing `@objc func importMedia(_ sender: Any?)`, add:

```swift
    @objc func importTimeline(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try FCPXMLImporter.importFile(at: url, into: editorViewModel)
            Log.project.notice("fcpxml import: \(summary.text)")
            if summary.clipsAdded == 0 {
                presentImportError("No importable clips found in \(url.lastPathComponent).")
            }
        } catch {
            presentImportError(error.localizedDescription)
        }
    }

    private func presentImportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Import Failed"
        alert.informativeText = message
        alert.runModal()
    }
```

Ensure `EditorWindowController.swift` imports what it needs: add `import UniformTypeIdentifiers` (for `UTType`) and `import AppKit` if not already present.

- [ ] **Step 4: Build and visually verify**

Run: `swift build` then `swift run`.
Open the File menu — "Import Timeline…" appears under Import Media…; choosing a `.fcpxml`
imports it into the open project (clips on the timeline, media in the panel; an alert on failure).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/App/MainMenu.swift Sources/PalmierPro/Editor/EditorWindowController.swift
git commit -m "feat: add File > Import Timeline menu for FCPXML

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Run the full test suite**

Run: `swift test`
Expected: all suites pass, including new `FCPTime`, `FCPXMLParser`, `FCPXMLImporter.build`.

- [ ] **End-to-end manual check (real astronaut file)**

1. `swift run`, open/create a project.
2. Via the agent (MCP): "import_timeline from `<…>/astronaut/projects/astronaut/build/astronaut.fcpxml`". Confirm ~50 image clips land on a video track at 24 fps and the PNGs appear in the media panel.
3. Via File → Import Timeline… : same file, confirm identical result into an empty project.
4. Import into a non-empty project: confirm the clips append as a new track (frames converted if fps differs).

- [ ] **Update AGENTS.md** Architecture with one line: FCPXML import (`Import/` — `FCPXMLParser` → `FCPXMLImporter`; surfaced via the `import_timeline` MCP tool and File → Import…). Commit.

---

## Notes for the implementer

- The parser is the pure, fully-tested seam; the importer's media/disk/editor glue (Task 5) and the menu (Task 7) are verified manually.
- Media is **referenced in place** (matching `import_media`'s `path` behavior) — the project points at the original files (incl. iCloud). Copying into the project's `media/` dir is a future option.
- v1 handles a single flat `<spine>` (lane 0). Connected clips on lanes are not split into extra tracks yet — note it if a test file uses lanes; it's a documented v1 limitation, not a bug.
- All new UI must use `AppTheme` tokens (the menu uses AppKit `NSMenu`/`NSAlert`, which are exempt).
