# FCPXML Timeline Import

**Date:** 2026-06-20
**Status:** Approved (design)

## Goal

Let Palmier import a timeline from an **FCPXML** file — parse it into a Palmier
`Timeline`, import the referenced media, and apply it to the open project. Driven both
by the agent (an `import_timeline` MCP tool) and by a native **File → Import…** menu.

Motivating input: the astronaut pipeline emits `astronaut.fcpxml` (FCPXML 1.10) — one
`<format>`, ~52 `<asset>`s each with a `<media-rep src="file://…png">`, and a single
`<sequence>`/`<spine>` of `<video>`/`<asset-clip>` placed sequentially. Palmier today
only *exports* XMEML and opens its own `.palmier` projects; there is no importer.

## Confirmed decisions

- **Format:** FCPXML (v1.x). XMEML/OTIO are explicit non-goals for v1.
- **Surfaces:** an `import_timeline` MCP tool **and** a File → Import… menu item, over one
  shared importer.
- **Target:** import into the **current** project — replace its timeline if empty,
  otherwise append the imported clips as new tracks below the existing ones.
- **Audio is in scope:** `<asset-clip>` with audio maps to an audio track (the astronaut
  file is image-only, but real timelines have audio and the mapping is cheap).
- **Fidelity:** support the constrained set below; unsupported constructs are
  **skipped and reported**, never fatal.

## Non-goals (v1)

- Full FCPXML fidelity. Skipped-and-reported: transitions, effects/filters,
  transform/crop/opacity adjustments + keyframes, `<title>` elements, compound clips /
  `<ref-clip>`, multicam, markers, color/grade.
- XMEML and OTIO import (the parser is structured so they could be added later).
- A media-access approval popup (separate feature). Import is user-initiated — choosing
  the `.fcpxml` (or the agent passing its path) is the consent. The non-sandboxed app
  reads the referenced files directly.

## Architecture

New `Sources/PalmierPro/Import/` directory, mirroring `Export/`. Three focused units plus
two thin surfaces.

```
Import/
  FCPTime.swift            — parse FCPXML rational time → seconds → frames (pure)
  FCPXMLParser.swift       — XMLDocument → ParsedTimeline value (pure, no app state)
  FCPXMLImporter.swift     — resolve media + build Palmier Timeline + apply to editor
Agent/Tools/
  ToolExecutor+ImportTimeline.swift  — `import_timeline` MCP tool
App/
  MainMenu.swift (modify)  — File → Import… → NSOpenPanel(.fcpxml) → importer
```

### FCPTime (pure)

FCPXML times are rational seconds: `"5s"`, `"116/24s"`, `"0s"`. Parse to `Double`
seconds; convert to frames at the timeline fps with rounding.

- `seconds(_ raw: String) -> Double?` — `"N/Ds"` → N/D; `"Ns"` → N; tolerant of missing
  `s`. Returns nil on garbage.
- `frames(_ raw: String, fps: Int) -> Int?` — `seconds × fps`, rounded.

### FCPXMLParser → `ParsedTimeline` (pure, the unit-test seam)

Parses the XML into a value type with no dependency on `EditorViewModel`:

```
struct ParsedTimeline {
    var fps: Int            // from <format> frameDuration (1/24s → 24)
    var width: Int
    var height: Int
    var assets: [String: ParsedAsset]   // id → asset
    var tracks: [ParsedTrack]           // spine + lanes, normalized to tracks
}
struct ParsedAsset { var id, name: String; var src: URL?; var hasVideo, hasAudio: Bool; var durationFrames: Int }
struct ParsedClip  { var assetId: String; var startFrame, durationFrames, sourceInFrames: Int; var kind: ClipKind }  // kind: video | image | audio | gap
struct ParsedTrack { var kind: TrackKind; var clips: [ParsedClip] }   // video | audio
```

Mapping rules:
- `<format>`: `frameDuration="1/24s"` → fps 24; `width`/`height` → timeline size.
- `<asset>` + child `<media-rep kind="original-media" src=…>`: decode the `file://` URL
  (percent-decoded); `hasVideo`/`hasAudio`; `duration` → frames. An image asset =
  `hasVideo && !hasAudio` with an image file extension.
- `<spine>` children in document order: `<video>`/`<asset-clip>` → `ParsedClip`
  (`offset`→startFrame, `duration`→durationFrames, `start`→sourceInFrames, `ref`→assetId);
  `<gap>` → advances offset (a gap clip). Connected clips with a `lane` attribute → a
  separate `ParsedTrack` (lane > 0 above, lane < 0 below); spine = lane 0.
- Audio assets / `<asset-clip>` referencing audio-only assets → an audio `ParsedTrack`.
- Unsupported elements (`<transition>`, `<title>`, `<ref-clip>`, filters/adjustments) are
  recorded into a `skipped: [String]` list and otherwise ignored.

### FCPXMLImporter (app-facing)

Takes a `ParsedTimeline` + the `EditorViewModel`, returns an `ImportSummary`.

1. **Resolve media** per asset: take `src`; if it's an iCloud placeholder, materialize it
   (`FileManager.startDownloadingUbiquitousItem(at:)` + poll for availability, bounded
   timeout); import via the existing `editor.addMediaAsset(from: url)`; record
   `assetId → MediaAsset.id`. Missing/unreadable → asset marked unresolved.
2. **Build tracks/clips**: for each `ParsedTrack`, create a Palmier `Track` of the right
   `ClipType`; for each `ParsedClip` with a resolved asset, create a `Clip`
   (`mediaRef` = imported id, `mediaType` from the asset, `startFrame`, `durationFrames`,
   `trimStartFrame` = sourceInFrames). Clips whose asset didn't resolve are skipped and
   counted. Gaps advance position (no clip).
3. **Apply**: set `editor.timeline.fps/width/height` from the parse **only when replacing**
   an empty timeline; when appending, keep the project's fps and convert frames to the
   project fps. Replace the timeline if it has no clips, else append the new tracks.
4. Return `ImportSummary { tracksAdded, clipsAdded, mediaImported, clipsSkipped, skipped[] }`.

### Surfaces

- **`import_timeline` MCP tool** (`ToolName.importTimeline = "import_timeline"`), args
  `{ path: String }`. Validates the path/extension, runs parser+importer on the current
  editor, returns the summary as text so the agent can report it. Registered in
  `ToolDefinitions`/`execute` so both the MCP server and in-app agent get it.
- **File → Import…** in `MainMenu`: `NSOpenPanel` restricted to `fcpxml`, then the same
  importer against the active project's `EditorViewModel`.

## Data flow

`import_timeline({path})` / menu → `FCPXMLParser.parse(url)` → `ParsedTimeline`
→ `FCPXMLImporter.import(parsed, into: editor)` → (resolve media via `addMediaAsset`,
materialize iCloud) → build `Track`/`Clip`s → apply to `editor.timeline` (replace/append)
→ `ImportSummary` back to the caller.

## Error handling

- Unreadable file / not XML / not `<fcpxml>` → clear error, nothing applied.
- Unknown fcpxml version → warn, attempt anyway (the schema is stable across 1.x for this
  subset).
- Missing/unreadable media (incl. iCloud download timeout) → that clip skipped, counted in
  the summary; import still proceeds.
- Zero resolvable clips → error ("no importable clips found").
- The editor mutation is applied once at the end (build fully, then assign) so a partial
  failure never leaves a half-built timeline.

## Testing

- **FCPTime** — `"5s"`, `"116/24s"`, `"0s"`, `"30000/1001s"`, garbage → expected
  seconds/frames. (unit)
- **FCPXMLParser** — an embedded astronaut-style FCPXML fixture (trimmed to a handful of
  assets + spine clips, incl. a `<gap>` and one unsupported element) → assert fps=24,
  asset count, each clip's startFrame/durationFrames/sourceInFrames, and that the
  unsupported element lands in `skipped`. (unit)
- **FCPXMLImporter build** — feed a `ParsedTimeline` with a stub media resolver (assetId →
  fake MediaAsset id, no disk) → assert track count, clip `startFrame`/`durationFrames`/
  `mediaRef`, append-vs-replace behavior, and skipped-clip counting. (unit)
- Live media resolution (iCloud download + `addMediaAsset`), the MCP tool end-to-end, and
  the File menu are manual/integration (need real files + GUI).

## Open notes (non-blocking)

- Frame-rate mismatch on append (e.g. importing a 24fps timeline into a 30fps project):
  v1 converts clip frames to the project fps by seconds; document that fractional results
  are rounded.
- `.fcpxmld` bundles (FCPXML packages) are out of scope; v1 handles the single-file
  `.fcpxml`.
