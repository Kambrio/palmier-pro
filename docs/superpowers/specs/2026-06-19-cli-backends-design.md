# CLI Backends: Claude Code CLI chat + Higgsfield CLI generation

**Date:** 2026-06-19
**Status:** Approved (design)

## Goal

Add local-CLI alternatives to the two AI features so they work without a Palmier
sign-in or an Anthropic API key — purely via the user's own CLI logins.

1. **Chat** gains a third backend: the **Claude Code CLI** (`claude`), alongside the
   existing Anthropic API key and Palmier sign-in. The CLI drives the timeline itself
   through the running Palmier MCP server.
2. **Generation** (image/video/audio) gains an alternative provider: the **Higgsfield
   CLI** (`higgsfield`, aka `hf`), alongside the existing Palmier (Convex) backend.

Both CLIs are usable fully standalone: no sign-in, no API key required.

## Confirmed decisions

- Generation CLI is **Higgsfield** (`higgsfield generate create …`), not HuggingFace.
- Claude CLI **drives tools via MCP** — the app does not run `ToolExecutor` for that path.
- MCP wiring: app calls always use an **inline `--mcp-config`** (scoped, no prompts);
  the app **also** runs `claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp`
  once so the user's interactive terminal gets Palmier too.
- Both CLIs work **fully standalone** (signed out, no API key).

## Non-goals

- No refactor of the existing Palmier/Convex or API-key paths beyond what's needed to
  make backend selection explicit.
- No attempt to unify Palmier's Convex model catalog with Higgsfield's — they remain
  separate catalogs surfaced through the same UI.
- No automation of the CLIs' own interactive logins beyond launching them
  (`claude` / `higgsfield auth login` open their own flows).

## Architecture overview

Two new "local CLI provider" seams, plus shared CLI plumbing.

```
Shared
  CLILocator        — resolve `claude` / `higgsfield` absolute paths (GUI PATH is minimal)
  CLIProcess        — async runner: spawn, stream stdout lines, capture stderr, timeout, cancel

Chat
  ChatBackend (enum, UserDefaults)  — .palmier | .apiKey | .claudeCLI  (+ availability)
  AgentService                       — selects backend; CLI path uses a separate turn-runner
  ClaudeCLIRunner                    — `claude -p … --output-format stream-json --verbose`,
                                       stream-json parser → AnthropicStreamEvent, session id per chat
  PalmierMCPConfig                   — inline --mcp-config JSON + `claude mcp add` registration

Generation
  GenerationProvider (enum, UserDefaults) — .palmier | .higgsfield
  HiggsfieldGenerationProvider            — generate create … --wait --json → result URL(s)
  HiggsfieldCatalog                       — `higgsfield model list --json` (cached) → model picker
```

### Shared: CLI plumbing

A non-sandboxed GUI app launched from Finder has a minimal `PATH`
(`/usr/bin:/bin:/usr/sbin:/sbin`), so neither `/opt/homebrew/bin/claude` nor
`/opt/homebrew/bin/higgsfield` is found by name.

- **`CLILocator`**: resolve an absolute binary path by checking, in order: a
  user-configured override (UserDefaults), common install dirs
  (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.claude/local`), then a
  login-shell `zsh -lc 'command -v <tool>'` fallback. Cache the result; expose
  `isAvailable` for UI.
- **`CLIProcess`**: thin async wrapper over `Process`/`Pipe` that yields stdout lines
  as an `AsyncThrowingStream`, captures stderr, supports cancellation (terminate the
  process) and a timeout. Used by both backends.

### Chat: Claude Code CLI backend

**Why it's not just another `AgentClient`.** The existing protocol passes `tools` and
expects `AgentService.runLoop()` to execute tool calls and feed results back. With the
CLI driving MCP, the CLI runs the whole agentic loop itself; the Palmier MCP server
(already mutating the live `EditorViewModel` via `editorProvider`) applies edits
directly. So the CLI path is a **separate turn-runner**, not a tool-loop client.

**Selection.** Replace today's implicit priority with an explicit `ChatBackend`
preference persisted in UserDefaults:

- `.palmier` — sign-in (existing `PalmierClient`)
- `.apiKey` — Anthropic key (existing `AnthropicClient`)
- `.claudeCLI` — Claude Code CLI (new)

`AgentService` resolves the effective backend = selected preference if available,
else fall back to the first available among {apiKey, palmier, claudeCLI}.
`canStream` is true if any backend is available. `.claudeCLI` is "available" when
`CLILocator` finds `claude` — independent of sign-in/API key (standalone).

**Turn flow (`runCLITurn`)** — used instead of `runLoop()` when backend is `.claudeCLI`:

1. Ensure the MCP server is running: if not, call `AppState.shared.startMCPService()`
   **once** (no self-recursion / retry loop); if it still isn't running, surface an
   actionable error ("Enable the MCP server in Settings to use the Claude CLI backend")
   and return.
2. Build the command:
   ```
   claude -p "<latest user text>"
     --output-format stream-json --verbose
     --model haiku            # default; see Models & cost controls below
     --max-turns 30           # hard cap on the agentic loop to bound token usage
     --mcp-config <inline JSON for palmier-pro http server>
     --strict-mcp-config
     --allowedTools "mcp__palmier-pro"      # server scope — NOT a __* glob (matches nothing)
     --disallowedTools "Bash Read Write Edit … WebFetch WebSearch Task"
     [--resume <sessionId>]   # after the first turn of this chat
     --append-system-prompt "<AgentInstructions.serverInstructions>"
   ```
   - `--strict-mcp-config` so only Palmier's server loads (no unrelated user servers).
   - `--allowedTools "mcp__palmier-pro"` pre-authorizes all Palmier MCP tools so the
     non-interactive run never blocks on a permission prompt. Use the **server scope**, not
     `mcp__palmier-pro__*` — the CLI matches MCP tools by server name, and a `__*` glob
     matches nothing, so every tool would prompt and be denied (cancelled) in -p mode.
   - `--disallowedTools "Bash Read Write …"` makes the backend MCP-only: it can't run
     built-in filesystem/exec tools, won't inherit the user's global Bash permissions, and
     won't wander onto the filesystem. (`ToolSearch` stays enabled to load deferred MCP tools.)
   - `--max-turns 30` bounds the CLI's internal agentic loop so a single chat turn can't
     silently spend a large amount of the user's Claude quota.
   - Mentions/`@` context and inlined images: passed as text appended to the prompt
     (image bytes referenced by path; the CLI can read project files if needed). v1 keeps
     this simple — text context only; image inlining is a follow-up note below.
3. Parse `stream-json` lines into existing `AnthropicStreamEvent`s:
   - `assistant` message text blocks → `.textDelta`
   - `assistant` `tool_use` blocks → `.toolUseComplete` (informational transcript only;
     **not** executed by the app)
   - tool results arrive as `user` lines from the CLI → surfaced as transcript markers
   - terminal `result` line → `.messageStop(.endTurn)` and capture `session_id`
4. Persist `session_id` on the `ChatSession` so the next turn passes `--resume`,
   giving the CLI true multi-turn continuity (the app does not replay history for this
   path).
5. Errors (non-zero exit, CLI not found, MCP down, not logged in) map to
   `PalmierClientError.upstream(message)` and render in the existing error UI.

**MCP registration.** On first use of the CLI backend (and idempotently), run
`claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp` so the user's
own terminal sessions also see Palmier. Failure here is non-fatal (the app's own calls
use the inline config regardless); log and continue.

**Models & cost controls.** The `claude -p` calls bill against the user's own Claude
subscription/limits, so the CLI backend is deliberately frugal by default:

- **Default model is Haiku.** The `.claudeCLI` backend has its own model preference
  (`ClaudeCLIModel`, UserDefaults) that **defaults to `.haiku45`**, independent of the
  Sonnet/Opus model used by the API-key and Palmier backends. `availableModels` for this
  backend lists `[.haiku45, .sonnet46, .opus47]` (Haiku first); the user can opt up to
  Sonnet/Opus explicitly, but nothing silently runs Opus.
- **Bounded per turn.** `--max-turns 30` caps the CLI's agentic loop.
- **No automatic retry.** A failed turn surfaces the error to the user; the app never
  silently re-invokes `claude` (that's what previously looked like runaway "retries").
- **No background spend.** Exactly one `claude` process per active turn; it is terminated
  on cancel/timeout (see process lifecycle below). No credits/API key needed.

**Process lifecycle (no stale `claude` processes).** Every `claude` invocation goes
through `CLIProcess`, which guarantees the child is terminated when:

- the user cancels the chat (`AgentService.cancel()` → the consuming task is cancelled →
  the stream's `onTermination` calls `process.terminate()`),
- the turn times out (a bounded wall-clock timeout terminates the process), or
- the app tears down the turn for any other reason (defer-based termination).

The runner never leaves a detached `claude` running after a turn ends, succeeds, or fails.

### Generation: Higgsfield CLI provider

**Selection.** A `GenerationProvider` preference in UserDefaults: `.palmier` (default,
Convex) or `.higgsfield` (CLI). When `.higgsfield`, `GenerationService` routes the
submit/upload/poll steps through `HiggsfieldGenerationProvider` instead of
`GenerationBackend`; the placeholder/finalize/download machinery is unchanged.

**Flow (image/video/audio).**

1. **No Convex upload.** Higgsfield's media flags accept a local file path and
   auto-upload it, so pass the reference assets' local file URLs directly — skip
   `GenerationBackend.uploadReference` entirely on this path.
2. Build and run, per kind:
   - **image:** `higgsfield generate create <model> --prompt "…" --image <ref1> [--image <ref2> …] --aspect_ratio <ar> --resolution <res> --wait --json`
   - **video:** same with `--start-image` / `--end-image` (and `--video`/`--audio` where
     the model supports them) mapped from the generation inputs
   - **audio:** the corresponding Higgsfield audio model with `--audio` / text params
   - `--wait` blocks until the job finishes and returns result URL(s) in JSON.
3. Parse the JSON for result URL(s); for N-image requests, map to the N placeholders.
4. Reuse the existing `downloadAndFinalize(asset:remoteURL:editor:)` to pull each result
   into the project `media/` dir — identical to the Convex path from here on.
5. Adopt astronaut's **result-is-input guard**: if a result URL matches an input
   reference UUID (`…/<uuid>_resize.jpg`), treat as failure and retry once.

**Model catalog.** Higgsfield models/params come from `higgsfield model list --image`
and `--video` (`--json`), built into a `HiggsfieldCatalog` and cached (refresh on demand
/ when stale). The generation UI's model picker reads from the active provider's catalog:
Palmier's `ModelCatalog` (Convex) or `HiggsfieldCatalog` (CLI). Param surfaces
(aspect ratio, resolution, duration) are derived from the catalog entry so the existing
generation UI can render them generically. Mapping of Palmier UI param names →
Higgsfield flag names lives in the provider.

**Auth & cost.** `higgsfield auth token --json` reports login state. If not logged in,
Settings shows an actionable row with a "Log in" button that runs
`higgsfield auth login` (opens the browser device flow). Cost: optionally call
`higgsfield generate cost …`; v1 may simply label Higgsfield generations as "metered by
Higgsfield" rather than showing Palmier credits.

### Settings UI

- **`AgentPane`** (already hosts API-key + MCP sections): add a **chat backend picker**
  (Sign in / API key / Claude Code CLI) with an availability/status row for the CLI
  (found at `<path>` / "claude not found", and an MCP-registered indicator), mirroring
  the existing MCP status row styling.
- **`ModelsPane`**: add a **generation provider picker** (Palmier / Higgsfield) with a
  Higgsfield auth-status row (logged in / "Log in" button) and binary-found status.
- All styling via `AppTheme`. Copy follows the product voice (action-verb-led, terse).

## Data flow

**Chat (CLI):** user message → `AgentService.runCLITurn` → `CLIProcess(claude … --mcp-config … --resume?)`
→ stream-json → transcript (text + tool markers); MCP server applies edits to the live
`EditorViewModel` as the CLI calls tools → `session_id` saved on the chat.

**Generation (Higgsfield):** `GenerationService.generate` → placeholders →
`HiggsfieldGenerationProvider` (`higgsfield generate create … --wait --json`, local refs
auto-uploaded) → result URL(s) → `downloadAndFinalize` → assets land in `media/`.

## Error handling

- CLI not found → Settings shows "not found"; selecting the backend is blocked/falls back
  with an actionable message.
- Not logged in (`claude` / `higgsfield`) → actionable error pointing to the login button.
- MCP server disabled when CLI chat is selected → error prompting to enable it.
- Non-zero exit / timeout / unparsable output → surfaced via the existing chat error UI
  (`streamError`) and generation `.failed(message)` placeholder state.
- Higgsfield result-is-input → retry once, then fail with a clear message.

## Testing

- **`CLILocator`**: resolution order, override wins, missing-binary path. (unit)
- **stream-json parser**: golden fixtures of real `claude --output-format stream-json`
  output → expected `AnthropicStreamEvent` sequence incl. `session_id` capture and
  tool_use-as-informational. (unit, no process spawn)
- **Higgsfield command builder**: GenerationInput (image/video/audio) → exact argv,
  including local-ref passthrough and param→flag mapping. (unit)
- **Higgsfield result parser**: `--json` fixtures → result URLs; result-is-input guard
  triggers retry. (unit)
- **ChatBackend selection**: preference + availability → effective backend and
  `availableModels`/`canStream`. (unit)
- Process-spawning paths are integration-tested manually (CLIs required); unit tests
  operate on fixtures and pure builders.

## Open implementation notes (non-blocking)

- Image-mention inlining for the CLI chat path is text-only in v1; passing image bytes to
  `claude -p` (base64 stdin / file refs) is a follow-up.
- Whether to expose a per-chat toggle vs. a global preference for chat backend — start
  global (simpler); revisit if users want per-chat.
