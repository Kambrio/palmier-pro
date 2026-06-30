# z.ai (GLM Coding Plan) Chat Backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fourth in-app chat backend, **z.ai (GLM Coding Plan)**, that drives the existing agentic loop against z.ai's Anthropic-compatible endpoint using a user-supplied API key.

**Architecture:** z.ai's coding plan exposes an Anthropic Messages-compatible endpoint at `https://api.z.ai/api/anthropic`. The existing `AnthropicRequestBody` builder and `AnthropicSSE` parser are reused verbatim; only the endpoint URL, the `Authorization: Bearer` header (instead of `x-api-key`), and GLM model ids differ. z.ai flows through the existing `runLoop()` — it is not a CLI backend.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, Foundation URLSession, Swift Testing (`@Test`/`@Suite`), macOS Keychain via `KeychainStore`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-29-zai-chat-backend-design.md`.
- All UI values come from `AppTheme.*` — never hardcode spacing/font/radius/opacity numbers. Match neighboring code exactly.
- Code style: minimal comments (one short line only when *why* is non-obvious). No `// removed X` breadcrumbs.
- Endpoint is fixed (not user-configurable): `https://api.z.ai/api/anthropic/v1/messages`. Auth is `Authorization: Bearer <key>` + `anthropic-version: 2023-06-01`. **No** `x-api-key`.
- Default z.ai model is **GLM-4.6** (`glm-4.6`) — chosen for low quota burn; picker also offers GLM-5.2 / GLM-4.7.
- Default selected backend stays `.claudeCLI`.
- Commit style: Conventional Commits with scope, e.g. `feat(agent): …`.
- Build/test commands: `swift build`, `swift test --filter <Suite>`.
- Repo is the Kambrio fork — never push or PR against `upstream` (`palmier-io`).
- Do **not** commit unless the plan step explicitly says to commit (repo AGENTS.md: only commit when requested). When a step says commit, stage only the files that step lists.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|-------|
| `Sources/PalmierPro/Agent/ChatBackend.swift` | backend enum, short names, fallback priority | modify |
| `Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift` | shared request-body builder | modify (`build` signature) |
| `Sources/PalmierPro/Agent/Clients/AnthropicClient.swift` | Anthropic keychain + client | modify (pass rawValue) + add `ZaiKeychain` |
| `Sources/PalmierPro/Agent/Clients/PalmierClient.swift` | Palmier sign-in client | modify (pass rawValue) |
| `Sources/PalmierPro/Agent/Clients/ZaiClient.swift` | z.ai client (new) | create |
| `Sources/PalmierPro/Agent/AgentService.swift` | backend orchestration | modify |
| `Sources/PalmierPro/Settings/SecureAPIKeyRow.swift` | reusable key-field view (new) | create |
| `Sources/PalmierPro/Settings/AgentPane.swift` | settings UI | modify |
| `Tests/PalmierProTests/CLI/ChatBackendTests.swift` | backend enum tests | modify |
| `Tests/PalmierProTests/CLI/ZaiClientTests.swift` | z.ai client request tests (new) | create |

---

## Task 1: Add `.zai` to `ChatBackend` enum

**Files:**
- Modify: `Sources/PalmierPro/Agent/ChatBackend.swift`
- Test: `Tests/PalmierProTests/CLI/ChatBackendTests.swift`

**Interfaces:**
- Produces: `ChatBackend.zai`, `ChatBackend.shortName` (`"Palmier"`, `"Anthropic"`, `"Claude CLI"`, `"z.ai"`), updated `effective()` priority `[claudeCLI, apiKey, zai, palmier]`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PalmierProTests/CLI/ChatBackendTests.swift` (inside the `struct ChatBackendTests { … }`):

```swift
    @Test func zaiParticipatesInEffectiveSelection() {
        #expect(ChatBackend.effective(selected: .zai, available: [.zai]) == .zai)
    }

    @Test func fallbackPlacesZaiAfterApiKeyBeforePalmier() {
        #expect(ChatBackend.effective(selected: .palmier,
                                      available: [.apiKey, .zai]) == .apiKey)
        #expect(ChatBackend.effective(selected: .palmier,
                                      available: [.zai]) == .zai)
    }

    @Test func zaiHasDisplayAndShortNames() {
        #expect(ChatBackend.zai.displayName == "z.ai (GLM Plan)")
        #expect(ChatBackend.zai.shortName == "z.ai")
    }

    @Test func everyBackendHasAShortName() {
        for b in ChatBackend.allCases {
            #expect(!b.shortName.isEmpty)
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PalmierProTests.ChatBackendTests`
Expected: compile failure — `zai` is not a member of `ChatBackend`; `shortName` does not exist.

- [ ] **Step 3: Implement the enum changes**

In `Sources/PalmierPro/Agent/ChatBackend.swift`:

Replace the `displayName` switch (lines 8–14) with both `displayName` and `shortName`:

```swift
    var displayName: String {
        switch self {
        case .palmier: "Palmier (sign in)"
        case .apiKey: "Anthropic API key"
        case .claudeCLI: "Claude Code CLI"
        case .zai: "z.ai (GLM Plan)"
        }
    }

    var shortName: String {
        switch self {
        case .palmier: "Palmier"
        case .apiKey: "Anthropic"
        case .claudeCLI: "Claude CLI"
        case .zai: "z.ai"
        }
    }
```

Add `.zai` to the `effective()` fallback list (line 34):

```swift
        for candidate in [ChatBackend.claudeCLI, .apiKey, .zai, .palmier] where available.contains(candidate) {
            return candidate
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PalmierProTests.ChatBackendTests`
Expected: PASS (all ChatBackend tests, new + existing).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/ChatBackend.swift Tests/PalmierProTests/CLI/ChatBackendTests.swift
git commit -m "feat(agent): add .zai ChatBackend case with short names"
```

---

## Task 2: Generalize `AnthropicRequestBody.build` to take a raw model id

**Files:**
- Modify: `Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift`
- Modify: `Sources/PalmierPro/Agent/Clients/AnthropicClient.swift`
- Modify: `Sources/PalmierPro/Agent/Clients/PalmierClient.swift`
- Test: `Tests/PalmierProTests/CLI/ZaiClientTests.swift` (create file, first test only here)

**Interfaces:**
- Produces: `AnthropicRequestBody.build(model: String, maxTokens: Int, system: String, tools: [AnthropicToolSchema], messages: [AnthropicMessage]) -> [String: Any]`. The signature changes from `model: AnthropicModel` to `model: String`; all other behavior (prompt-cache boundaries) is unchanged.

- [ ] **Step 1: Write the failing test**

Create `Tests/PalmierProTests/CLI/ZaiClientTests.swift`:

```swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("ZaiClient + request builder")
struct ZaiClientTests {

    @Test func buildAcceptsRawModelString() {
        let body = AnthropicRequestBody.build(
            model: "glm-4.6", maxTokens: 8, system: "s", tools: [], messages: [])
        #expect(body["model"] as? String == "glm-4.6")
        #expect(body["max_tokens"] as? Int == 8)
        #expect(body["stream"] as? Bool == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PalmierProTests.ZaiClientTests`
Expected: compile failure — `build(model:)` expects `AnthropicModel`, not `String`.

- [ ] **Step 3: Change the builder signature**

In `Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift`, replace the `build(model: AnthropicModel, …)` declaration (around line 158) so the first parameter is a `String`:

```swift
enum AnthropicRequestBody {
    static func build(
        model: String,
        maxTokens: Int,
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> [String: Any] {
```

Inside the same function body, the line `"model": model.rawValue,` becomes `"model": model,` (it now receives a raw string). Everything else in the function stays identical.

- [ ] **Step 4: Update the two callers to pass `.rawValue`**

In `Sources/PalmierPro/Agent/Clients/AnthropicClient.swift` (inside `run`, around line 72), change:

```swift
            withJSONObject: AnthropicRequestBody.build(
                model: model, maxTokens: maxTokens, system: system, tools: tools, messages: messages
            ),
```

to:

```swift
            withJSONObject: AnthropicRequestBody.build(
                model: model.rawValue, maxTokens: maxTokens, system: system, tools: tools, messages: messages
            ),
```

In `Sources/PalmierPro/Agent/Clients/PalmierClient.swift` (inside `run`, around line 50), make the identical change (`model: model` → `model: model.rawValue`).

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter PalmierProTests.ZaiClientTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift Sources/PalmierPro/Agent/Clients/AnthropicClient.swift Sources/PalmierPro/Agent/Clients/PalmierClient.swift Tests/PalmierProTests/CLI/ZaiClientTests.swift
git commit -m "refactor(agent): pass raw model id to AnthropicRequestBody.build"
```

---

## Task 3: Add `ZaiKeychain` + `.zaiAPIKeyChanged` notification

**Files:**
- Modify: `Sources/PalmierPro/Agent/Clients/AnthropicClient.swift`

**Interfaces:**
- Produces: `Notification.Name.zaiAPIKeyChanged`, `enum ZaiKeychain` with `save(_:)`, `load() -> String?`, `delete()`, keychain account `"zai-api-key"`, DEBUG env override `ZAI_API_KEY`.

- [ ] **Step 1: Add the notification name and keychain enum**

In `Sources/PalmierPro/Agent/Clients/AnthropicClient.swift`, add a second entry to the existing `Notification.Name` extension (top of file):

```swift
extension Notification.Name {
    static let anthropicAPIKeyChanged = Notification.Name("anthropicAPIKeyChanged")
    static let zaiAPIKeyChanged = Notification.Name("zaiAPIKeyChanged")
}
```

Then, immediately after the `AnthropicKeychain` enum (after its closing `}` around line 30), add a parallel `ZaiKeychain`:

```swift
enum ZaiKeychain {
    private static let account = "zai-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .zaiAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["ZAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .zaiAPIKeyChanged, object: nil)
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/AnthropicClient.swift
git commit -m "feat(agent): add ZaiKeychain for z.ai API key storage"
```

---

## Task 4: Add `ZaiModel` enum + `ZaiModelPreference`

**Files:**
- Modify: `Sources/PalmierPro/Agent/ChatBackend.swift`
- Test: `Tests/PalmierProTests/CLI/ChatBackendTests.swift`

**Interfaces:**
- Produces: `enum ZaiModel: String, CaseIterable, Sendable` (`glm46 = "glm-4.6"`, `glm52 = "glm-5.2"`, `glm47 = "glm-4.7"`) with `displayName`; `enum ZaiModelPreference` with `static var value: ZaiModel` (UserDefaults `io.palmier.pro.chat.zai.model`, default `.glm46`).

- [ ] **Step 1: Write the failing test**

Append to `Tests/PalmierProTests/CLI/ChatBackendTests.swift`:

```swift
    @Test func zaiModelDefaultsToGlm46() {
        UserDefaults.standard.removeObject(forKey: "io.palmier.pro.chat.zai.model")
        #expect(ZaiModelPreference.value == .glm46)
    }

    @Test func zaiModelRawValuesAndDisplayNames() {
        #expect(ZaiModel.glm46.rawValue == "glm-4.6")
        #expect(ZaiModel.glm52.rawValue == "glm-5.2")
        #expect(ZaiModel.glm47.rawValue == "glm-4.7")
        #expect(ZaiModel.allCases.count == 3)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PalmierProTests.ChatBackendTests`
Expected: compile failure — `ZaiModel` / `ZaiModelPreference` undefined.

- [ ] **Step 3: Add the types**

In `Sources/PalmierPro/Agent/ChatBackend.swift`, add immediately after the `ClaudeCLIModelPreference` enum (after its closing `}` around line 54):

```swift
enum ZaiModel: String, CaseIterable, Sendable {
    case glm46 = "glm-4.6"
    case glm52 = "glm-5.2"
    case glm47 = "glm-4.7"

    var displayName: String {
        switch self {
        case .glm46: "GLM-4.6"
        case .glm52: "GLM-5.2"
        case .glm47: "GLM-4.7"
        }
    }
}

enum ZaiModelPreference {
    private static let key = "io.palmier.pro.chat.zai.model"
    static var value: ZaiModel {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let m = ZaiModel(rawValue: raw) { return m }
            return .glm46
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PalmierProTests.ChatBackendTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/ChatBackend.swift Tests/PalmierProTests/CLI/ChatBackendTests.swift
git commit -m "feat(agent): add ZaiModel and ZaiModelPreference (default GLM-4.6)"
```

---

## Task 5: Implement `ZaiClient`

**Files:**
- Create: `Sources/PalmierPro/Agent/Clients/ZaiClient.swift`
- Test: `Tests/PalmierProTests/CLI/ZaiClientTests.swift`

**Interfaces:**
- Consumes: `AnthropicRequestBody.build(model:maxTokens:system:tools:messages:)` (Task 2), `AnthropicSSE.parse` (existing), `AnthropicClientError` (existing), `ZaiModel` (Task 4).
- Produces: `struct ZaiClient: AgentClient` with `init(apiKey:model:maxTokens:)`, `stream(system:tools:messages:)`, and a pure static `makeRequest(apiKey:model:maxTokens:system:tools:messages:) throws -> URLRequest` used both by `run` and by tests.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PalmierProTests/CLI/ZaiClientTests.swift` (inside the suite):

```swift
    @Test func requestTargetsZaiAnthropicEndpointWithBearerAuth() throws {
        let msg = AnthropicMessage(role: .user, content: [["type": "text", "text": "hi"]])
        let req = try ZaiClient.makeRequest(
            apiKey: "k", model: "glm-4.6", maxTokens: 8,
            system: "s", tools: [], messages: [msg])
        #expect(req.url == ZaiClient.endpoint)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        // z.ai uses Bearer auth, never the Anthropic x-api-key header.
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(req.value(forHTTPHeaderField: "accept") == "text/event-stream")
    }

    @Test func requestBodyCarriesGlmModel() throws {
        let req = try ZaiClient.makeRequest(
            apiKey: "k", model: ZaiModel.glm46.rawValue, maxTokens: 8,
            system: "s", tools: [], messages: [])
        let body = try #require(req.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "glm-4.6")
        #expect(json["stream"] as? Bool == true)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PalmierProTests.ZaiClientTests`
Expected: compile failure — `ZaiClient` undefined.

- [ ] **Step 3: Create the client**

Create `Sources/PalmierPro/Agent/Clients/ZaiClient.swift`:

```swift
import Foundation

/// Drives the agentic chat loop through z.ai's Anthropic-compatible coding-plan
/// endpoint. Body shape and SSE events are identical to api.anthropic.com; only
/// the endpoint, Bearer auth, and GLM model ids differ.
struct ZaiClient: AgentClient {
    let apiKey: String
    let model: ZaiModel
    var maxTokens: Int = 8192

    static let endpoint = URL(string: "https://api.z.ai/api/anthropic/v1/messages")!

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AnthropicClientError.missingAPIKey }

        let request = try Self.makeRequest(
            apiKey: apiKey, model: model.rawValue, maxTokens: maxTokens,
            system: system, tools: tools, messages: messages)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw AnthropicClientError.httpError(status: http.statusCode, body: body)
        }

        try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
    }

    /// Pure + static so request construction is unit-testable without a network call.
    static func makeRequest(
        apiKey: String,
        model: String,
        maxTokens: Int,
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: AnthropicRequestBody.build(
                model: model, maxTokens: maxTokens, system: system, tools: tools, messages: messages),
            options: [.sortedKeys])
        return request
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PalmierProTests.ZaiClientTests`
Expected: PASS (both request-building tests + the `build` test from Task 2).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/ZaiClient.swift Tests/PalmierProTests/CLI/ZaiClientTests.swift
git commit -m "feat(agent): add ZaiClient against z.ai Anthropic-compatible endpoint"
```

---

## Task 6: Wire z.ai into `AgentService`

**Files:**
- Modify: `Sources/PalmierPro/Agent/AgentService.swift`

**Interfaces:**
- Consumes: `ChatBackend.zai` (Task 1), `ZaiKeychain` + `.zaiAPIKeyChanged` (Task 3), `ZaiModel`/`ZaiModelPreference` (Task 4), `ZaiClient` (Task 5).
- Produces: `AgentService.hasZaiKey`, `.zai` in `availableBackends`, backend-aware `selectClient()` returning `ZaiClient` for `.zai`, `.zai` case in `availableModels`, updated `send()` no-backend message.

- [ ] **Step 1: Add the z.ai key state + observer**

In `Sources/PalmierPro/Agent/AgentService.swift`, add two stored properties next to the existing `apiKey`/`apiKeyObserver` (top of the class, around lines 8–9):

```swift
    private var apiKey: String = ""
    private var apiKeyObserver: NSObjectProtocol?
    private var zaiKey: String = ""
    private var zaiKeyObserver: NSObjectProtocol?
```

In `init()` (around lines 11–22), register the z.ai observer alongside the Anthropic one. After the existing `apiKeyObserver = …` block, add:

```swift
        reloadZaiKey()
        zaiKeyObserver = NotificationCenter.default.addObserver(
            forName: .zaiAPIKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadZaiKey()
            }
        }
```

(Run `reloadAPIKey()` stays as the first line of `init`; add `reloadZaiKey()` as shown.)

Add the loader + computed, mirroring `reloadAPIKey`/`hasApiKey` (place them right after `reloadAPIKey`/`hasApiKey`, around lines 24–39):

```swift
    private func reloadZaiKey() {
        Task { [weak self] in
            let key = await Task.detached(priority: .utility) {
                ZaiKeychain.load() ?? ""
            }.value
            self?.zaiKey = key
        }
    }
```

and add `hasZaiKey` next to `var hasApiKey`:

```swift
    var hasApiKey: Bool { !apiKey.isEmpty }
    var hasZaiKey: Bool { !zaiKey.isEmpty }
```

In `isolated deinit` (around lines 33–37), also remove the z.ai observer:

```swift
    isolated deinit {
        if let token = apiKeyObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = zaiKeyObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }
```

- [ ] **Step 2: Add `.zai` to `availableBackends`**

In `availableBackends` (around lines 45–52), add the z.ai line:

```swift
    var availableBackends: Set<ChatBackend> {
        var set: Set<ChatBackend> = []
        if hasApiKey { set.insert(.apiKey) }
        if hasZaiKey { set.insert(.zai) }
        let account = AccountService.shared
        if account.isSignedIn && account.hasCredits { set.insert(.palmier) }
        if isClaudeCLIAvailable { set.insert(.claudeCLI) }
        return set
    }
```

- [ ] **Step 3: Add a `.zai` case to `availableModels` and a `zaiModel` accessor**

In `availableModels` (around lines 60–67), add the `.zai` case (its return value is unused by the z.ai client, which uses `ZaiModel`; it only needs to satisfy the switch):

```swift
    var availableModels: [AnthropicModel] {
        switch effectiveBackend {
        case .apiKey: return AnthropicModel.allCases
        case .claudeCLI: return [.haiku45, .sonnet46, .opus48]   // Haiku first = default
        case .palmier: return AccountService.shared.isPaid ? [.sonnet46] : [.haiku45]
        case .zai: return [.sonnet46]
        case .none: return [.sonnet46]
        }
    }
```

Add a `zaiModel` accessor immediately after `availableModels`:

```swift
    var zaiModel: ZaiModel { ZaiModelPreference.value }
```

- [ ] **Step 4: Make `selectClient()` backend-aware**

Replace the current `selectClient()` (lines 69–76):

```swift
    private func selectClient() -> (any AgentClient)? {
        let chosen = effectiveModel
        if hasApiKey { return AnthropicClient(apiKey: apiKey, model: chosen) }
        if AccountService.shared.isSignedIn {
            return PalmierClient(model: chosen)
        }
        return nil
    }
```

with a switch on `effectiveBackend`:

```swift
    private func selectClient() -> (any AgentClient)? {
        let chosen = effectiveModel
        switch effectiveBackend {
        case .apiKey:
            return AnthropicClient(apiKey: apiKey, model: chosen)
        case .palmier:
            return AccountService.shared.isSignedIn ? PalmierClient(model: chosen) : nil
        case .zai:
            guard hasZaiKey else { return nil }
            return ZaiClient(apiKey: zaiKey, model: zaiModel)
        case .claudeCLI, .none:
            return nil
        }
    }
```

> Note: this makes `selectClient` honor the user's selected backend even when both an API key and Palmier sign-in are present. `effectiveBackend` is already the source of truth for `canStream`/`kickOffStream`, so this aligns `selectClient` with them. The fallback priority in `ChatBackend.effective()` is unchanged.

- [ ] **Step 5: Update the `send()` no-backend message**

In `send(text:mentions:)` (around line 318), change:

```swift
            streamError = .upstream("Sign in, add an Anthropic API key, or install the Claude Code CLI to start.")
```

to:

```swift
            streamError = .upstream("Sign in, add an Anthropic or z.ai API key, or install the Claude Code CLI to start.")
```

- [ ] **Step 6: Verify it builds and existing tests pass**

Run: `swift build && swift test --filter PalmierProTests.ChatBackendTests`
Expected: build succeeds; backend tests still pass (`.zai` now satisfies all switches).

- [ ] **Step 7: Commit**

```bash
git add Sources/PalmierPro/Agent/AgentService.swift
git commit -m "feat(agent): wire z.ai backend into AgentService"
```

---

## Task 7: Settings UI — reusable key row, z.ai key section, z.ai model picker

**Files:**
- Create: `Sources/PalmierPro/Settings/SecureAPIKeyRow.swift`
- Modify: `Sources/PalmierPro/Settings/AgentPane.swift`

**Interfaces:**
- Consumes: `ChatBackend.shortName` (Task 1), `ZaiKeychain` (Task 3), `ZaiModel`/`ZaiModelPreference` (Task 4).
- UI-only task (no unit test): verify by `swift build` then launching and manually checking Settings → Agent. AppTheme constants only.

- [ ] **Step 1: Create the reusable `SecureAPIKeyRow`**

Create `Sources/PalmierPro/Settings/SecureAPIKeyRow.swift`:

```swift
import AppKit
import SwiftUI

/// Reusable secure API-key field with masked placeholder, Save/Remove controls,
/// and a "get a key" link. Used for both the Anthropic and z.ai key sections.
struct SecureAPIKeyRow: View {
    let title: String
    let description: String
    let getKeyURL: URL
    let getKeyLabel: String
    let placeholderPrefix: String
    let hasKey: Bool
    let maskedKey: String
    @Binding var draft: String
    var onSave: () -> Void
    var onRemove: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            fieldRow
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(description)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: {
                    NSWorkspace.shared.open(getKeyURL, configuration: .init(), completionHandler: nil)
                }) {
                    HStack(spacing: 2) {
                        Text(getKeyLabel)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    private var fieldRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            fieldBox
            trailingControl
        }
    }

    private var fieldBox: some View {
        SecureField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit { onSave(); isFocused = false }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.black.opacity(AppTheme.Opacity.muted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isFocused)
    }

    private var placeholder: String { hasKey ? maskedKey : placeholderPrefix }

    @ViewBuilder
    private var trailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save") { onSave(); isFocused = false }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove API key")
        }
    }
}
```

- [ ] **Step 2: Update `AgentPane` state properties**

In `Sources/PalmierPro/Settings/AgentPane.swift`, replace the existing Anthropic-only state block (lines 6–14):

```swift
    @State private var hasKey: Bool = false
    @State private var maskedKey: String = ""
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool
    @State private var backend: ChatBackend = ChatBackend.selected
    @State private var claudeFound: Bool = false
    @State private var cliModel: AnthropicModel = ClaudeCLIModelPreference.value

    private let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")!
```

with parallel Anthropic + z.ai state (the `@FocusState` moves into `SecureAPIKeyRow`, so remove it here):

```swift
    @State private var anthropicHasKey: Bool = false
    @State private var anthropicMasked: String = ""
    @State private var anthropicDraft: String = ""
    @State private var zaiHasKey: Bool = false
    @State private var zaiMasked: String = ""
    @State private var zaiDraft: String = ""
    @State private var backend: ChatBackend = ChatBackend.selected
    @State private var claudeFound: Bool = false
    @State private var cliModel: AnthropicModel = ClaudeCLIModelPreference.value
    @State private var zaiModel: ZaiModel = ZaiModelPreference.value

    private let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")!
    private let zaiSubscribeURL = URL(string: "https://z.ai/subscribe")!
```

- [ ] **Step 3: Insert the z.ai key section into the body**

In the `body` (lines 17–27), insert `zaiKeySection` after `apiKeySection`:

```swift
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            backendSection
            Divider().overlay(AppTheme.Border.subtleColor)
            apiKeySection
            Divider().overlay(AppTheme.Border.subtleColor)
            zaiKeySection
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
            Divider().overlay(AppTheme.Border.subtleColor)
            skillsSection
            Divider().overlay(AppTheme.Border.subtleColor)
            transcriptSection
        }
```

- [ ] **Step 4: Use `shortName` in the backend picker and add the z.ai model branch**

In `backendSection` (lines 92–112), change the picker label and add an `else if backend == .zai` branch:

```swift
    private var backendSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Chat Backend")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Picker("", selection: $backend) {
                ForEach(ChatBackend.allCases, id: \.self) { b in
                    Text(b.shortName).tag(b)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: backend) { _, newValue in ChatBackend.selected = newValue }

            if backend == .claudeCLI {
                claudeCLIStatusRow
                claudeCLIModelPicker
            } else if backend == .zai {
                zaiModelPicker
            }
        }
    }
```

Add the `zaiModelPicker` view (place it right after `claudeCLIModelPicker`, around line 148):

```swift
    private var zaiModelPicker: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Model")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Picker("", selection: $zaiModel) {
                ForEach(ZaiModel.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: zaiModel) { _, v in ZaiModelPreference.value = v }
        }
    }
```

- [ ] **Step 5: Replace the Anthropic key section + add the z.ai key section**

Replace the current `apiKeySection`, `header`, `keyField`, `fieldBox`, `trailingControl`, `placeholder`, `refresh`, `applyKey`, `save`, `remove`, `loadKey`, and `mask` members (lines 150–283) with the slimmer versions below. The section bodies now delegate to `SecureAPIKeyRow`; the keychain logic stays in `AgentPane`.

```swift
    private var apiKeySection: some View {
        SecureAPIKeyRow(
            title: "Anthropic API Key",
            description: "Used your own API key for the AI chat. Stored in your macOS Keychain.",
            getKeyURL: consoleURL,
            getKeyLabel: "Get Anthropic API key",
            placeholderPrefix: "sk-ant-...",
            hasKey: anthropicHasKey,
            maskedKey: anthropicMasked,
            draft: $anthropicDraft,
            onSave: saveAnthropic,
            onRemove: removeAnthropic
        )
    }

    private var zaiKeySection: some View {
        SecureAPIKeyRow(
            title: "z.ai API Key",
            description: "Use the GLM Coding Plan for the AI chat. Stored in your macOS Keychain.",
            getKeyURL: zaiSubscribeURL,
            getKeyLabel: "Get z.ai key",
            placeholderPrefix: "...",
            hasKey: zaiHasKey,
            maskedKey: zaiMasked,
            draft: $zaiDraft,
            onSave: saveZai,
            onRemove: removeZai
        )
    }

    private func refresh() {
        Task { @MainActor in
            async let aKey = Self.load(AnthropicKeychain.load)
            async let zKey = Self.load(ZaiKeychain.load)
            let (a, z) = (await aKey, await zKey)
            anthropicHasKey = !a.isEmpty
            anthropicMasked = Self.mask(a)
            zaiHasKey = !z.isEmpty
            zaiMasked = Self.mask(z)
            claudeFound = CLILocator(tool: "claude").resolve(override: nil) != nil
        }
    }

    private static func load(_ loader: @escaping @Sendable () -> String?) async -> String {
        await Task.detached(priority: .utility) { loader() ?? "" }.value
    }

    private func saveAnthropic() {
        let key = anthropicDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        anthropicDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { AnthropicKeychain.save(key) }.value
            anthropicHasKey = true
            anthropicMasked = Self.mask(key)
        }
    }

    private func removeAnthropic() {
        anthropicDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { AnthropicKeychain.delete() }.value
            anthropicHasKey = false
            anthropicMasked = ""
        }
    }

    private func saveZai() {
        let key = zaiDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        zaiDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { ZaiKeychain.save(key) }.value
            zaiHasKey = true
            zaiMasked = Self.mask(key)
        }
    }

    private func removeZai() {
        zaiDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { ZaiKeychain.delete() }.value
            zaiHasKey = false
            zaiMasked = ""
        }
    }

    private static func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: builds with no errors. If `isFocused` is reported as unused/missing, confirm you removed the old `@FocusState private var isFocused` from `AgentPane` (it now lives in `SecureAPIKeyRow`).

- [ ] **Step 7: Manual verification — launch and check Settings**

The agent sandbox lacks the Developer ID keychain identity, so re-sign ad-hoc before opening:

```bash
kill $(pgrep -f PalmierPro.app/Contents/MacOS/PalmierPro) 2>/dev/null; sleep 1
swift build && ./scripts/bundle.sh debug --fast
codesign --force --deep --sign - .build/PalmierPro.app
open .build/PalmierPro.app
```

Open Settings → Agent and confirm:
1. The Chat Backend segmented control shows four short labels: **Palmier · Anthropic · Claude CLI · z.ai**.
2. Selecting **z.ai** shows the GLM model picker (GLM-4.6 selected by default; GLM-5.2 / GLM-4.7 available).
3. A **z.ai API Key** section appears below the Anthropic API Key section; paste a key → Save → field masks; trash icon removes it.
4. Selecting **Anthropic** / **Claude CLI** still behaves as before (no regression in their sections).
5. With a z.ai key saved and z.ai selected, send a chat message and confirm it streams a reply (validates the live endpoint + Bearer auth).

- [ ] **Step 8: Commit**

```bash
git add Sources/PalmierPro/Settings/SecureAPIKeyRow.swift Sources/PalmierPro/Settings/AgentPane.swift
git commit -m "feat(agent): add z.ai API key section and model picker to Settings"
```

---

## Final verification

- [ ] Run the full test suite: `swift test`
  Expected: all suites pass, including `ChatBackendTests` and `ZaiClientTests`.
- [ ] `swift build` clean.
- [ ] Manual end-to-end (Task 7 Step 7) confirms a live z.ai turn streams.

## Notes for the implementer

- Do not run `bundle.sh`/`dev.sh` without the ad-hoc re-sign shown in Task 7 Step 7 — the sandbox keychain lacks the Developer ID identity and the bundle won't launch otherwise.
- This is the Kambrio fork. Push/PR only against `origin` (`Kambrio/palmier-pro`), never `upstream`.
- If `glm-4.6` is rejected by the coding endpoint at runtime (HTTP 4xx with a model-not-found message), switch the default to `glm-4.7` by editing `ZaiModelPreference`'s default — but do **not** change it speculatively; only if a real request fails.
