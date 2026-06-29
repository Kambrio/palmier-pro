# PalmierPro

AI-native macOS video editor. Swift 6.2, SwiftUI + AppKit, AVFoundation. macOS 26 only, arm64 only. Non-sandboxed Developer ID app.

## Build, run, test

```bash
swift build
swift run                       # build + launch from SPM
./scripts/dev.sh                # bundled debug .app, launched, streaming OSLog (subsystem io.palmier.pro)
./scripts/dev.sh --no-stream    # launch without tailing logs
swift test                                              # full suite (Swift Testing + XCTest)
swift test --filter RippleEngineTests                   # one suite/type
swift test --filter PalmierProTests.TimeFormattingTests # fully-qualified
```

`scripts/bundle.sh` builds the `.app`; `scripts/release.sh` builds + notarizes for Developer ID distribution (Sparkle `appcast.xml`).

## Restarting after a build

After every successful build, **restart the running app** so the user sees the change — `open` alone reactivates the old instance. Quit first (the app sometimes ignores the graceful ask, so `kill` the pid), rebuild, then relaunch.

In the agent's sandboxed shell the Developer ID identity isn't in the keychain, so `bundle.sh`/`dev.sh` `--fast` signing fails and leaves the bundle unlaunchable. Re-sign ad-hoc before opening:

```bash
kill $(pgrep -f PalmierPro.app/Contents/MacOS/PalmierPro) 2>/dev/null; sleep 1
swift build && ./scripts/bundle.sh debug --fast
codesign --force --deep --sign - .build/PalmierPro.app
open .build/PalmierPro.app
```

(On the user's own machine `./scripts/dev.sh --no-stream` works directly — it has the keychain identity.)

## Git & PRs

This is the **Kambrio fork** of `palmier-io/palmier-pro`. All work goes to the fork — **never push or open PRs against `upstream` (`palmier-io`)**. `origin` (`Kambrio`) is the remote you commit, push, and PR against; `upstream` is read-only (fetch only, for syncing).

- Branch off `origin/main`, push to `origin`, and open PRs with `base: main` on **`Kambrio/palmier-pro`**:
  ```bash
  gh pr create --repo Kambrio/palmier-pro --base main --head <branch>
  ```
  (Without `--repo`, `gh` targets the upstream parent and fails with "No commits between main and …".)
- Commit style: Conventional Commits with a scope — `feat(shots):`, `fix(stab):`, `feat(timeline):`, `docs:`, …

## Architecture

The whole editor revolves around one observable model and one shared command surface.

- **`EditorViewModel`** (`Editor/ViewModel/`) is the central `@MainActor @Observable` state for an open project: the `Timeline`, `MediaManifest`, `GenerationLog`, selection, playhead, focus. It's huge by design and split across `EditorViewModel+*.swift` extensions (ClipMutations, Ripple, Keyframes, Tracks, Linking, MediaLibrary, AIEdit, …) — each editing capability is one extension file. Add new editing operations as a new extension, not inline.
- **`Timeline` / `Track` / `Clip`** (`Models/Timeline.swift`) is the pure-value, `Codable` document model. Everything is frame-based (integer frames at `timeline.fps`), not seconds. Mutating `editorViewModel.timeline` bumps `timelineRenderRevision`, which drives re-render.
- **`VideoProject: NSDocument`** (`Project/`) owns persistence. A `.palmier` project is a file *package* (directory): `project.json` (timeline), `media.json` (manifest), `generation-log.json`, `thumbnail.jpg`, and a `media/` dir — names in `Project` enum (`Utilities/Constants.swift`). Autosave-in-place; decode happens off-main, applied on main.
- **`AppState.shared`** (`App/`) is the app-level singleton: holds `activeProject`, starts/stops the MCP service, switches Home ↔ Editor windows.

**Agent + MCP share one executor.** `ToolExecutor` (`Agent/Tools/`) is the single implementation of every timeline operation an LLM can perform (addClips, ripple delete, setKeyframes, generate, captions, search…), again split across `ToolExecutor+*.swift`. Two front-ends call into it:
  - **`MCPService` / `MCPHTTPServer`** expose it over HTTP at `127.0.0.1:19789/mcp` for external agents (Claude Code, Codex, Cursor). Enabled by default via UserDefaults.
  - **In-app agent** (`Agent/Panel/`, `Agent/Clients/`) drives the same tools from the chat panel.
  Tool schemas live in `ToolDefinitions.swift`; the model-facing prompt is `AgentInstructions.swift`. When you add a tool, wire it in `ToolName`/`execute`, define its schema, and it's available to both front-ends at once.

**Local-CLI backends (no sign-in / no API key).** Selectable alternatives that shell out to locally-installed CLIs via the shared `CLILocator`/`CLIProcess` (`Utilities/`):
  - **Chat** (`ChatBackend`): besides API key and Palmier sign-in, the **Claude Code CLI** backend (`Agent/Clients/ClaudeCLI/`) runs `claude -p … --output-format stream-json` with an inline Palmier `--mcp-config`, so the CLI itself drives MCP tools against the live editor (the app does *not* run `ToolExecutor` for this path). It defaults to Haiku, caps turns with `--max-turns`, never auto-retries, and runs one process per turn terminated on cancel/timeout. Picked in `Settings/AgentPane`.
  - **Generation** (`GenerationProvider`): the **Higgsfield CLI** provider (`Generation/Higgsfield/`) replaces the Convex submit/upload/poll with `higgsfield generate create … --wait --json` (local refs auto-upload), then reuses the existing download/finalize path. Picked in `Settings/ModelsPane`.

**Rendering/preview** (`Preview/`): `CompositionBuilder` turns the frame-based timeline into an `AVComposition` + Core Animation layers; `VideoEngine` plays it; text/Lottie/image clips are rendered to video by their generators. **Export** (`Export/`) reuses the composition path and also writes FCP `XMLExporter` and `.palmier` bundles.

**Stabilization** (`Stabilization/`): all on-device, no round-trip. `StabilizationManager` (on `EditorViewModel`) drives four modes: native path smoothing (`PathSmoother`/`TrackPath` — locked/cinematic/organic), FFmpeg `vid.stab` (`VidStab`/`FFmpegStabService`), **Subject Lock** (`SubjectTracker` + the YOLO `ObjectDetector` keeps a person/object steady), **Point Track** (`PointSetTracker` holds position/rotation/scale). Results persist as sidecars (`StabilizationSidecar`). Agent/MCP tool: `stabilize_clips`.

**Other subsystems:** `Generation/` (closed-source generative AI — Seedance/Kling/Nano Banana via `GenerationService`), `Search/` (on-device SigLIP2 visual search + transcript search, models under `models/`), `Transcription/` (captions/transcripts), `Account/` (Clerk + Convex auth, gates generative features).

**Shot Library** (`ShotLibrary/`): per-footage understanding for the editor and the agent. `ShotLibraryManager` (on `EditorViewModel`) samples 3 frames per video (10/50/90%), runs on-device Apple Vision (`FrameVisionAnalyzer`: scene classification, face detection → shot size & people, capture quality, feature-print identity grouping) plus the bundled YOLO `ObjectDetector` and the transcript, then composes a baseline description and a meaningful name. Persisted as `shot-library.json` at the package root (same read/write/snapshot path as `generation-log.json`); thumbnails in `media/shots/`. The meaningful name flows onto the timeline via `clipDisplayLabel(for:)`. Editing UI is `ShotLibraryView` (Documents tab). Frame analysis blends Apple Vision with a zero-shot `SigLIPShotClassifier` that reuses the SigLIP2 search model (`VisualModelLoader.shared.embedder`) when installed — no extra download. Agent/MCP tools: `analyze_footage`, `get_shot_library`, `set_shot`.

**Story Graph** (`StoryGraph` model + `StoryGraphManager` + `StoryTemplates` + `StoryGraphView`): an interactive node-graph for developing a video's story from footage. Nodes are options at levels direction → structure → act → beat → block; beats link to footage/captions/documents. Hand-rolled SwiftUI Canvas graph (pan/zoom, layered-by-depth layout). Persisted as `story-graph.json` (same path as the shot library). Opened from the Documents tab. Agent/MCP tools: `get_story_graph`, `add_story_nodes`, `set_story_node`, `remove_story_node`.

**Skills.** App-bundled creative skills live in `Sources/PalmierPro/Resources/Skills/<name>/SKILL.md` (scriptwriter, storytelling-craft, video-hooks, video-scripting, write-metadata, montage-editing, story-development). `ClaudeCLISkills` materializes them for the in-app `claude -p` chat, and (opt-in via Settings → Agent → Skills) installs them into the user's global `~/.claude/skills/` so their own terminal `claude` sessions discover them.

## Code style

- Keep comments minimal. Only write one when the *why* is non-obvious. Don't restate what the code does, don't narrate the current change, don't leave `// removed X` breadcrumbs. One short line max — no multi-line comment blocks or paragraph docstrings.

## Design System

All UI styling MUST use `AppTheme` constants from `Sources/PalmierPro/UI/AppTheme.swift`. Never use hardcoded numeric values for:

- **Spacing/padding** → `AppTheme.Spacing.*` (xxs through xxl)
- **Font sizes** → `AppTheme.FontSize.*` (xxs through display)
- **Font weights** → `AppTheme.FontWeight.*` (regular, medium, semibold, bold)
- **Corner radii** → `AppTheme.Radius.*` (xs through xl)
- **Border widths** → `AppTheme.BorderWidth.*` (hairline, thin, medium, thick)
- **Opacity** → `AppTheme.Opacity.*` (subtle, faint, muted, medium, strong, prominent)
- **Icon frame sizes** → `AppTheme.IconSize.*` (xs through xl)
- **Shadows** → `AppTheme.Shadow.*` (sm, md, lg) via `.shadow(AppTheme.Shadow.md)`
- **Colors** → `AppTheme.Text.*`, `AppTheme.Border.*`, `AppTheme.Background.*`
- **Animation durations** → `AppTheme.Anim.*`

If a needed value doesn't exist in AppTheme, add it there first — don't hardcode it.

## Drag and drop

SwiftUI `.onDrop` on a parent view shadows every drop target inside its layout area on macOS 26 — even AppKit `NSDraggingDestination` children registered directly with the window. Inner `.onDrop` modifiers silently never fire while a parent `.onDrop` is active.

Rule: **any drop target that spans an area containing other drop targets must use native AppKit** (see `MediaPanelDropArea` in `Sources/PalmierPro/MediaPanel/`). Inner / leaf drops can stay SwiftUI `.onDrop`. Do not stack SwiftUI `.onDrop` modifiers in parent/child layouts.

## Voice

Palmier Pro speaks like a quietly capable native Mac app for filmmakers: direct, technical, calm, and 
confident. Prefer Apple HIG-style terseness over warmth. Never chatty or cute. Never marketing. When the
product needs to ask for action, lead with the action verb; when it reports state, name the thing.

