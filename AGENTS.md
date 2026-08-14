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

**Syncing upstream.** To pull `palmier-io` changes: from a branch off `origin/main`, `git merge upstream/main`, resolve conflicts keeping fork features, build + test, then PR to `Kambrio:main`. The fork is far ahead and intentionally divergent — e.g. `GenerationService` stays fork-side (local-first Higgsfield CLI + OmniVoice); upstream's online-generation refactor (`prepareReferences`, recovery jobs, `resumePendingGenerations`) is incompatible with the fork's local-first direction and is **not** adopted.

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

**Other subsystems:** `Generation/` (in the fork this is **local-first**: Higgsfield CLI for video/image, OmniVoice for local TTS — see *Local-CLI backends* above. The legacy Palmier online/Convex submit-upload-poll path still lives in `GenerationService` but is slated for removal; don't build new features on it), `Search/` (on-device SigLIP2 visual search + transcript search, models under `models/`), `Transcription/` (captions/transcripts), `Account/` (Clerk + Convex auth, gates the legacy online features).

**Shot Library** (`ShotLibrary/`): per-footage understanding for the editor and the agent. `ShotLibraryManager` (on `EditorViewModel`) samples 3 frames per video (10/50/90%), runs on-device Apple Vision (`FrameVisionAnalyzer`: scene classification, face detection → shot size & people, capture quality, feature-print identity grouping) plus the bundled YOLO `ObjectDetector` and the transcript, then composes a baseline description and a meaningful name. Persisted as `shot-library.json` at the package root (same read/write/snapshot path as `generation-log.json`); thumbnails in `media/shots/`. The meaningful name flows onto the timeline via `clipDisplayLabel(for:)`. Editing UI is `ShotLibraryView` (Documents tab). Frame analysis blends Apple Vision with a zero-shot `SigLIPShotClassifier` that reuses the SigLIP2 search model (`VisualModelLoader.shared.embedder`) when installed — no extra download. Shot size is a canonical 8-value image-backed scale (`ShotSize`: extreme close-up → master, tight to wide); on-device detection (`ShotAnalyzer` face/coverage heuristics) and the SigLIP classifier map onto it, and each of the 3 frames has a {preview + text} dropdown in `ShotLibraryView` to correct misdetections — corrections stick across re-analysis. Legacy `medium` decodes as `mediumFull`. Agent/MCP tools: `analyze_footage`, `get_shot_library`, `set_shot` (which exposes `shotSize`).

**Story Graph** (`StoryGraph` model + `StoryGraphManager` + `StoryTemplates` + `StoryGraphView`): an interactive node-graph for developing a video's story from footage. Nodes are options at levels direction → structure → act → beat → block; beats link to footage/captions/documents. Hand-rolled SwiftUI Canvas graph (pan/zoom, layered-by-depth layout). Persisted as `story-graph.json` (same path as the shot library). Opened from the Documents tab. Agent/MCP tools: `get_story_graph`, `add_story_nodes`, `set_story_node`, `remove_story_node`.

**Skills.** App-bundled creative skills live in `Sources/PalmierPro/Resources/Skills/<name>/SKILL.md` (scriptwriter, storytelling-craft, video-hooks, video-scripting, write-metadata, montage-editing, story-development). `ClaudeCLISkills` materializes them for the in-app `claude -p` chat, and (opt-in via Settings → Agent → Skills) installs them into the user's global `~/.claude/skills/` so their own terminal `claude` sessions discover them.

## Code style

- Keep comments minimal. Write one only when the why, invariant, safety constraint, or framework workaround is non-obvious.
- Comments are one short line maximum. Do not narrate code, restate names, describe the current patch, leave removal breadcrumbs, add commented-out code, or write paragraph docstrings for internal APIs.
- Prefer precise names, small types, and extracted operations over explanatory comments.
- Complex logic must have a single source of truth. Never copy a calculation or business rule into another file or surface.
- Remove dead code, unused state, obsolete compatibility paths, and temporary diagnostics before finishing.
- Do not add compatibility code for OS versions or architectures Palmier Pro does not support.

## Concurrency and the main actor

- Treat the main actor as a scarce UI resource. It may own UI state and lightweight coordination state, but it must not perform file I/O, media decoding, model inference, image processing, indexing, export work, blocking framework calls, or large collection transforms.
- `@MainActor` provides isolation, not performance. Move expensive work out of a main-actor type instead of assuming an `async` method makes it safe.
- `Task {}` inherits actor isolation. Never use it as evidence that synchronous work moved off the main actor.
- `nonisolated` on a synchronous function does not switch threads. A call from the main thread still runs on the main thread.
- Make executor changes explicit. Prefer an asynchronous system API; otherwise use a dedicated utility queue or service, an `@concurrent` async function, or a carefully bounded `Task.detached` over immutable `Sendable` snapshots.
- Snapshot the minimum immutable input before leaving an actor. Return a value, then apply it on the owning actor after checking cancellation and confirming the result is still current.
- At every `await`, assume actor-isolated state may have changed. Revalidate identity, generation, configuration, selection, lifecycle state, and preconditions before committing a result.
- Prefer structured concurrency. Unstructured tasks must have a clear owner, stored handle when cancellation matters, and teardown behavior.
- Cancellation is cooperative. Long operations and loops must check cancellation at useful boundaries, and cancellation must not commit partial or stale results.
- Bound parallel work according to the actual scarce resource. Do not create one task per asset, frame, thumbnail, decoder, or model request without a concurrency limit.
- Deduplicate identical in-flight work where multiple callers can request the same result.
- Actors protect their own state only. Audit process-global state, C/C++ libraries, Metal resources, AVFoundation objects, caches, and third-party dependencies before allowing separate actors to call them concurrently.
- Acquire and release gates in matched scopes. Install `defer` only after acquisition succeeds. Make cancellation while waiting safe.
- Keep continuation state in one isolation domain and resume every continuation exactly once on success, failure, or cancellation.
- Never block the main thread with `DispatchQueue.sync`, semaphore waits, group waits, locks, polling, or synchronous waits for async work.
- Treat Objective-C and third-party callback isolation as untrusted unless documented. Hop explicitly to the correct actor and use `@Sendable` where a callback crosses isolation.
- Avoid `nonisolated(unsafe)` and unchecked `Sendable`. Any use requires a concrete invariant and targeted coverage.

## File I/O and project packages

- Every filesystem operation must execute off the main actor and main thread. This includes reads, writes, encoding to or decoding from disk, existence checks, metadata and resource-value queries, directory enumeration, coordination, copying, moving, replacing, deleting, and directory creation.
- Assume every volume can be slow, removable, externally modified, or network-backed. File size and a successful previous access do not make synchronous main-thread access safe.
- Prefer asynchronous APIs. Run synchronous Foundation file APIs behind an explicit background boundary, preferably a dedicated serial utility queue for coordinated operations.
- The synchronous `FileIO` helpers do not provide an execution hop. Callers are responsible for invoking them from an off-main context.
- Snapshot actor-owned model data before file work. Do not capture a main-actor model or mutate observable state from the file-I/O executor.
- Stage complete output outside the live project package, prepare replacements on the destination volume, and atomically install the finished item.
- Route all live `.palmier` package media installs and removals through `ProjectPackageCoordinator`. Do not write directly into a live package from feature code.
- Serialize operations that target the same package or destination. A save, import, generation result, thumbnail, removal, export, and close operation must not race each other.
- Closing, Save As, and app termination must wait for admitted mutations, reject late commits, and preserve the latest successful state.
- Use unique temporary paths and clean them on success, failure, and cancellation. Never delete or replace a destination until the complete replacement is ready.
- Surface user-requested file failures. Do not hide them with `try?`, empty results, or success-shaped responses.

## Performance

- Treat rendering, playback, scrubbing, audio metering, timeline input, SwiftUI view updates, import, indexing, restore, save, and export as performance-sensitive paths.
- Do not perform filesystem access, logging, JSON encoding, model setup, decoder or reader creation, audio-graph setup, LUT parsing, `CIContext` creation, or other blocking setup inside per-frame, per-sample, per-grain, per-item view, or repeated interaction paths.
- Measure before claiming a performance improvement. Use the relevant Instruments template, signposts, a focused benchmark, or a performance test, then compare before and after under the same workload.
- Fix algorithmic complexity and unnecessary work before applying low-level optimizations. Watch for nested scans, repeated sorting, copy-on-write mutation in loops, intermediate arrays, repeated actor hops, and repeated observation invalidation.
- Batch and coalesce bulk mutations. Preserve explicit consistency boundaries by flushing pending state before save snapshots, undo snapshots, export, close, and reads that promise current data.
- Load and hydrate media lazily. Do not decode thumbnails, waveforms, filmstrips, metadata, transcripts, or models until a consumer needs them.
- Cache expensive reusable work only with an explicit key, capacity, invalidation rule, replacement rule, lifecycle behavior, and stale-result policy.
- Reuse expensive AVFoundation, Core Image, Metal, audio, and model objects when their documented lifecycle permits it. Invalidate them on relevant configuration and application lifecycle changes.
- Keep high-frequency observable state as narrow as possible. A progress counter, meter, or playhead update must not invalidate an entire panel or large media grid.
- Keep SwiftUI `body` work fast and side-effect free. Precompute expensive derived data and observe the smallest state surface that can render the result.
- Limit retained media and cache memory. Use bounded caches, release temporary buffers promptly, and use scoped autorelease pools for large Objective-C media loops when profiling shows retained temporaries.
- Keep per-item success logging out of release hot paths. Production logs should preserve actionable warnings, failures, and batch summaries without evaluating verbose messages unnecessarily.

## Correctness and edge cases

- “Works on the happy path” is not sufficient. Before implementing, enumerate the applicable boundary, lifecycle, concurrency, and failure cases and decide which layer owns each behavior.
- Validate empty, nil, zero, negative, maximum, overflowing, non-finite, malformed, duplicated, missing, stale, and unsupported inputs as applicable.
- Validate before integer arithmetic, frame addition, duration multiplication, indexing, or numeric conversion. Never rely on a later `do`/`catch` to catch a Swift arithmetic trap.
- Define exact rounding and clamping behavior. Do not silently clamp an invalid request unless tolerance is an intentional documented part of the contract.
- Cover no-op and repeated operations. They must report accurately and must not create mutations, undo entries, duplicate work, or misleading success.
- Consider cancellation before start, during each phase, after work completes but before commit, and while waiting for a gate or callback.
- Consider stale completion after selection, timeline, project, asset URL, model, mix, generation, or configuration changes.
- Consider close, quit, sleep, wake, app deactivation, device changes, Save As, and teardown while work is active.
- Consider empty timelines, zero-duration media, missing tracks, corrupt or offline media, variable frame rates, non-integer speeds, time-scale conversion, and long-duration projects.
- Consider linked clips, nested timelines, multicam groups, locked or sync-locked tracks, split clips, overlapping clips, and changes to a child timeline after a carrier was created.
- Consider interaction combinations: keyboard modifiers, Escape, dismissal, mouse-up after cancellation, disabled controls, focus changes, selection changes, and overlapping gestures.
- Consider partial filesystem failure, permissions, an existing destination, identical source and destination, external changes, low space, and cleanup failure.
- Preserve project invariants on every failure path. Partial success must either be safely resumable and reported as such or rolled back.

## Editor mutations and undo

- Route UI and Agent edits through the same domain mutation operations and shared `EditorUndo` history.
- One coherent user intent should produce one undoable action. Do not expose internal substeps as separate undo entries unless they are independently meaningful to the user.
- Validate arguments and preconditions before opening an undo group. Failed, cancelled, refused, and unchanged operations must not create empty undo steps.
- Nested implementation work must coalesce into the outer user action without closing groups owned by AppKit or another subsystem.
- Undo must restore exact state without cumulative frame rounding, derived-state drift, orphaned linked clips, or stale selection.
- Test interleaving between UI edits, Agent edits, automatic AppKit event grouping, project switching, and concurrent tool requests when the change touches undo.

## Agent tool design

- Design tools from user intent, not from internal APIs, database operations, view models, or service method boundaries.
- Start with representative user requests and define the desired outcome, success criteria, warnings, failure behavior, cancellation behavior, retry behavior, idempotency, and undo semantics before defining the schema.
- A tool should perform one coherent filmmaker action. One call should normally complete one atomic, understandable, and undoable workflow.
- Do not force the Agent to reproduce application orchestration by chaining low-level tools when Palmier Pro can safely perform the workflow itself.
- Do not create a broad “god tool” with unrelated modes. Group operations only when they share one user goal, validation model, and result shape.
- Express parameters in filmmaking and user-facing domain concepts. Hide storage layout, framework objects, UI state, and incidental implementation details.
- Use stable entity IDs for automation. Positional indexes and display labels may be returned for context but must not be the only durable identity after edits.
- Treat every tool argument as untrusted. Require exact types, finite numbers, explicit bounds, valid identifiers, and supported combinations before mutation or arithmetic.
- Resolve and validate the full request before mutating state. Apply multi-entity changes atomically and preserve all editor invariants.
- Reuse the same domain operation as the UI. Agent tools must not duplicate timeline math, placement, linking, sync, media, export, or project logic.
- Return structured receipts describing what changed, stable IDs, explicit no-op state, warnings, skipped items, and actionable errors. Do not return a success-shaped response when the requested outcome was adjusted or not achieved.
- Do not silently clamp, retarget, reorder, fall back, or select a different entity unless the tool contract explicitly promises that behavior and reports it.
- Long-running tools must expose a durable job or terminal result that the Agent can inspect. Asynchronous failure must not disappear after the initiating call returns.
- Keep Agent and MCP protocol values stable and machine-facing. Localize UI copy separately; do not serialize localized labels, errors, statuses, or undo names into tool contracts.
- Tool descriptions must explain when and why to use the tool, important constraints, and interactions with other tools. Do not merely restate parameter names.
- Refactoring internal APIs must not require changing a well-designed tool contract unless the user-visible capability changes.

## AVFoundation and media processing

- Use AVFoundation asynchronous property loading. Do not access deprecated synchronous `AVAsset`, `AVAssetTrack`, or `AVMetadataItem` properties that may block the calling thread.
- Keep exact media time in `CMTime` or frame-domain integers as long as possible. Convert to `Double` only at explicit UI or external-format boundaries.
- Define and preserve time scale, rounding, source-versus-timeline time, speed, trim, transform, color, alpha, audio layout, and metadata semantics.
- Keep potentially blocking AVFoundation and Core Audio setup and control calls off the main thread, even when the API does not advertise itself as file I/O.
- Reuse readers, render contexts, audio graphs, and pipelines where appropriate. Do not rebuild them during continuous interaction unless invalidation requires it.
- Bound concurrent decoders, readers, exports, model inference, thumbnail generation, and waveform extraction.
- Propagate cancellation through decode, render, inference, export, and generation loops. Check between chunks when an underlying synchronous API cannot be cancelled.
- Preserve source color attachments, transforms, frame timing, channel layout, and other media metadata unless the feature explicitly changes them.
- Test with missing audio or video tracks, unusual containers, zero or indefinite duration, rotated media, alpha media, nonstandard sample rates, and cancellation.

## SwiftUI and AppKit

- Keep observable UI state on the main actor and make background results cross that boundary as immutable values.
- Scope observation to the smallest view that needs the value. High-frequency progress, meter, hover, and playback state must not invalidate unrelated view trees.
- Do not start persistent side effects from `body`. Use lifecycle-aware tasks or controllers with explicit cancellation and teardown.
- Preserve native Mac behavior for keyboard focus, Escape, Return, menus, window restoration, undo, drag state, sheets, and close confirmation.
- AppKit delegate and completion-handler contracts must complete exactly once on every success, failure, cancellation, and missing-target path.
- Do not assume an AppKit or AVFoundation callback arrives on the main thread unless the API guarantees it.

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

## SwiftUI Menu image labels

A `Menu` (default or `.menuStyle(.borderlessButton)`) renders its label's `Image` at the `NSImage`'s **natural pixel size** and bypasses SwiftUI `.frame()` / `.clipShape()` on it — so an unbounded bundled image in a menu label will blow up the layout, and a `.clipShape` won't round its corners. Bake both into the `NSImage` itself: pin `.size` to a small edge, and draw rounded corners via `NSImage(size:flipped:drawingHandler:)` with an `NSBezierPath` clip (see `ShotSizeArtwork`). SwiftUI layout modifiers alone won't constrain a menu-rendered image.

## Voice

Palmier Pro speaks like a quietly capable native Mac app for filmmakers: direct, technical, calm, and confident. Prefer Apple HIG-style terseness over warmth. Never chatty or cute. Never marketing. When the product needs to ask for action, lead with the action verb; when it reports state, name the thing.

## Primary references

- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Diagnosing performance issues early](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)
- [Improving performance and stability when accessing the file system](https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system)
- [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/)
- [Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/)
- [Swift concurrency data-race safety](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/)
- [Task cancellation](https://developer.apple.com/documentation/swift/task/)
- [Improving your app's performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)
- [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)
- [Loading media data asynchronously](https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously)
- [Swift Testing](https://developer.apple.com/documentation/testing)
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
