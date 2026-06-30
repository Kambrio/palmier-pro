# z.ai (GLM Coding Plan) Chat Backend

**Date:** 2026-06-29
**Status:** Approved

## Goal

Add a fourth in-app chat backend, **z.ai (GLM Coding Plan)**, selectable alongside
Palmier sign-in, Anthropic API key, and Claude Code CLI. The user configures a z.ai API
key in Settings (stored in macOS Keychain, like the Anthropic key) and picks a GLM model.
The backend drives the existing in-app agentic loop against the live editor.

## Why this is cheap

z.ai's GLM Coding Plan exposes an **Anthropic Messages-compatible endpoint** at
`https://api.z.ai/api/anthropic` (this is how Claude Code speaks to it). The request body
shape, tool-calling schema, and SSE streaming events are identical to `api.anthropic.com`.
The existing `AnthropicRequestBody` builder and `AnthropicSSE` parser are reused verbatim —
only the endpoint URL, the auth header (`Authorization: Bearer` instead of `x-api-key`),
and the model id strings differ. No OpenAI-protocol translation layer is needed.

## Constraints & risks

- **z.ai ToS:** the GLM Coding Plan is "strictly limited to use within officially supported
  tools" (Claude Code, Cline, OpenCode, Cursor, …). Palmier is not on that list, so z.ai
  *may* restrict the subscription if it detects unsupported-tool usage. The user has
  explicitly accepted this risk and chosen the coding endpoint
  (`https://api.z.ai/api/anthropic`). Endpoint is **not** user-configurable in this design.
- **Default model:** **GLM-4.6** is the default. It's nearly the same quality as the
  newer GLM-5.2 but consumes less coding-plan quota per turn, so it's the economical
  everyday choice (mirrors how the Claude CLI backend defaults to Haiku to conserve the
  user's own quota). The picker also exposes GLM-5.2 and GLM-4.7 for harder tasks.

## Design

### 1. Backend enum — `Agent/ChatBackend.swift`

- New case `.zai` with `displayName: "z.ai (GLM Plan)"`.
- New `shortName: "z.ai"` (and short names for the other three) used by the segmented
  picker in Settings so four segments fit.
- `effective()` fallback priority becomes `[claudeCLI, apiKey, zai, palmier]`.
- Default selected backend stays `.claudeCLI`.

### 2. Keychain — `ZaiKeychain` (in `Agent/Clients/AnthropicClient.swift`)

Parallel to `AnthropicKeychain`:

- Keychain account `"zai-api-key"`.
- `save(_:)` / `load()` / `delete()`.
- Posts `.zaiAPIKeyChanged` on save/delete.
- DEBUG-only env override `ZAI_API_KEY` (mirrors `ANTHROPIC_API_KEY`).

### 3. Client — new `Agent/Clients/ZaiClient.swift`

`struct ZaiClient: AgentClient`:

- Endpoint: `https://api.z.ai/api/anthropic/v1/messages`.
- Headers: `Authorization: Bearer <key>`, `anthropic-version: 2023-06-01`,
  `content-type: application/json`, `accept: text/event-stream`. **No** `x-api-key`.
- Reuses `AnthropicRequestBody.build(model: String, …)` and `AnthropicSSE.parse`.
- Same `stream(system:tools:messages:)` shape as `AnthropicClient`; yields
  `AnthropicStreamEvent`s that the existing `runLoop()` already consumes.
- Error type reuses `AnthropicClientError` (`missingAPIKey`, `httpError`, `streamError`).

### 4. Models — `ZaiModel` + `ZaiModelPreference`

- `enum ZaiModel: String, CaseIterable, Sendable`:
  - `glm46 = "glm-4.6"` — **default**
  - `glm52 = "glm-5.2"`
  - `glm47 = "glm-4.7"`
  - `displayName`: `"GLM-4.6"`, `"GLM-5.2"`, `"GLM-4.7"`.
- `enum ZaiModelPreference` with UserDefaults key
  `io.palmier.pro.chat.zai.model`, default `.glm46`. Mirrors
  `ClaudeCLIModelPreference`.

### 5. Shared request-builder refactor — `Agent/Clients/AgentClientTypes.swift`

`AnthropicRequestBody.build(model: AnthropicModel, …)` →
`build(model: String, …)`. The model id is the only Anthropic-model-specific input;
passing a raw string lets both `AnthropicClient`/`PalmierClient` (`.rawValue`) and
`ZaiClient` (`.rawValue`) share one builder. Prompt-cache logic is unchanged.

### 6. `AgentService` wiring — `Agent/AgentService.swift`

- Add `zaiKey: String` + `hasZaiKey`; reload from `ZaiKeychain.load()` in `init` and on
  `.zaiAPIKeyChanged` (mirror the existing `apiKey`/observer pair, clean up in `deinit`).
- `availableBackends`: insert `.zai` when `hasZaiKey`.
- Make `selectClient()` backend-aware (it currently ignores `effectiveBackend`):
  ```swift
  switch effectiveBackend {
  case .apiKey: return AnthropicClient(apiKey: apiKey, model: effectiveModel)
  case .palmier: return AccountService.shared.isSignedIn
      ? PalmierClient(model: effectiveModel) : nil
  case .zai:    return hasZaiKey
      ? ZaiClient(apiKey: zaiKey, model: zaiModel) : nil
  case .claudeCLI, .none: return nil
  }
  ```
  where `zaiModel` resolves `ZaiModelPreference.value` (with availability clamp).
- `availableModels` switch gets a `.zai` case (returns the Anthropic default list — it
  only influences the unrelated `effectiveModel`; the z.ai client uses `ZaiModel`).
- `.zai` is **not** a CLI backend, so `kickOffStream()` routes it through the existing
  `runLoop()` (the only branch is `== .claudeCLI`); no new turn loop.
- Update `send()` no-backend message: "Sign in, add an Anthropic or z.ai API key, or
  install the Claude Code CLI to start."

### 7. Settings UI — `Settings/AgentPane.swift`

- Segmented backend picker uses `shortName` (4 segments now fit).
- Extract a small reusable `SecureAPIKeyRow` view (secure field + masked placeholder +
  Save/Remove trailing control) because there are now two identical key fields. Both the
  Anthropic and z.ai key sections use it; behavior and styling are unchanged.
- New **z.ai API Key** section (placed after the Anthropic API Key section): header
  "z.ai API Key", copy referencing the GLM Coding Plan, "Get z.ai key" link →
  `https://z.ai/subscribe`. Bound to `ZaiKeychain`.
- New **z.ai model picker** shown when `backend == .zai` (parallel to
  `claudeCLIModelPicker`), bound to `ZaiModelPreference`.

## Tests — `Tests/PalmierProTests/CLI/ChatBackendTests.swift`

- `effective()` includes `.zai`: selected `.zai` + available → `.zai`; fallback priority
  places `.zai` after `.apiKey`.
- Default selected backend remains `.claudeCLI`.
- `ZaiClient` request-building test: endpoint URL, `Authorization: Bearer` header present,
  no `x-api-key`, `anthropic-version` header, body `model == "glm-4.6"`. (Mirror any
  existing Anthropic client request test; if none exists, assert via a small
  `argv`/request-builder-style pure helper.)

## Files

| File | Change |
|------|--------|
| `Agent/ChatBackend.swift` | `.zai` case, `displayName`, `shortName`, `effective()` priority |
| `Agent/Clients/AnthropicClient.swift` | add `ZaiKeychain`, `.zaiAPIKeyChanged` |
| `Agent/Clients/AgentClientTypes.swift` | `AnthropicRequestBody.build(model: String, …)` |
| `Agent/Clients/PalmierClient.swift` | pass `model.rawValue` |
| `Agent/Clients/ZaiClient.swift` | **new** |
| `Agent/AgentService.swift` | `zaiKey`/observer, `availableBackends`, backend-aware `selectClient`, `availableModels` `.zai` case, `send()` copy |
| `Settings/AgentPane.swift` | `shortName` picker, `SecureAPIKeyRow` extraction, z.ai key section, z.ai model picker |
| `Tests/…/ChatBackendTests.swift` | `.zai` cases + `ZaiClient` request test |

## Out of scope

- OpenAI-protocol path (`/api/paas/v4`).
- User-configurable endpoint.
- Usage/quota display.
- Streaming usage/token accounting beyond what `AnthropicSSE` already logs.
