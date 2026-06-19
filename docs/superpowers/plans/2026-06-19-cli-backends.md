# CLI Backends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Claude Code CLI chat backend (drives the timeline via the Palmier MCP server) and a Higgsfield CLI generation provider, both usable with no Palmier sign-in and no API key.

**Architecture:** Two "local CLI provider" seams sharing CLI plumbing. Chat gains an explicit `ChatBackend` preference; the `.claudeCLI` path is a separate turn-runner in `AgentService` that shells out to `claude -p … --output-format stream-json` with an inline Palmier MCP config and lets the running MCP server apply edits. Generation gains a `GenerationProvider` preference; the `.higgsfield` path replaces the Convex submit/upload/poll with `higgsfield generate create … --wait --json`, then reuses the existing download/finalize machinery.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, `Foundation.Process`/`Pipe`, Swift Testing (`import Testing`). Design tokens via `AppTheme`. Spec: `docs/superpowers/specs/2026-06-19-cli-backends-design.md`.

---

## File structure

**Shared (new):**
- `Sources/PalmierPro/Utilities/CLILocator.swift` — resolve absolute paths to `claude` / `higgsfield`.
- `Sources/PalmierPro/Utilities/CLIProcess.swift` — async `Process` runner: stream stdout lines, capture stderr, timeout, cancel.

**Chat (new + modify):**
- `Sources/PalmierPro/Agent/ChatBackend.swift` (new) — backend enum + UserDefaults preference + availability.
- `Sources/PalmierPro/Agent/Clients/ClaudeCLI/PalmierMCPConfig.swift` (new) — inline `--mcp-config` JSON + `claude mcp add` registration.
- `Sources/PalmierPro/Agent/Clients/ClaudeCLI/ClaudeStreamJSONParser.swift` (new) — parse `stream-json` lines → `AnthropicStreamEvent` + session id.
- `Sources/PalmierPro/Agent/Clients/ClaudeCLI/ClaudeCLIRunner.swift` (new) — build argv, run, stream events.
- `Sources/PalmierPro/Agent/AgentService.swift` (modify) — `ChatBackend` selection, `runCLITurn`, per-session CLI session id.
- `Sources/PalmierPro/Agent/ChatSessionStore.swift` (modify) — add `cliSessionId`.
- `Sources/PalmierPro/Settings/AgentPane.swift` (modify) — backend picker + CLI status row.

**Generation (new + modify):**
- `Sources/PalmierPro/Generation/Higgsfield/GenerationProvider.swift` (new) — provider enum + preference + auth status.
- `Sources/PalmierPro/Generation/Higgsfield/HiggsfieldCommand.swift` (new) — `GenerationInput` → argv builder.
- `Sources/PalmierPro/Generation/Higgsfield/HiggsfieldResult.swift` (new) — parse `--json` output → result URLs + result-is-input guard.
- `Sources/PalmierPro/Generation/Higgsfield/HiggsfieldGenerationProvider.swift` (new) — orchestrate a generation via the CLI.
- `Sources/PalmierPro/Generation/Higgsfield/HiggsfieldCatalog.swift` (new) — `higgsfield model list --json` → model picker entries.
- `Sources/PalmierPro/Generation/GenerationService.swift` (modify) — route upload + `runJob` by provider.
- `Sources/PalmierPro/Settings/ModelsPane.swift` (modify) — provider picker + Higgsfield auth status row.

**Tests (new):**
- `Tests/PalmierProTests/CLI/CLILocatorTests.swift`
- `Tests/PalmierProTests/CLI/ClaudeStreamJSONParserTests.swift`
- `Tests/PalmierProTests/CLI/ChatBackendTests.swift`
- `Tests/PalmierProTests/Generation/HiggsfieldCommandTests.swift`
- `Tests/PalmierProTests/Generation/HiggsfieldResultTests.swift`

Build/test commands: `swift build`; `swift test --filter <SuiteName>`.

---

## Phase 0 — Shared CLI plumbing

### Task 1: CLILocator

**Files:**
- Create: `Sources/PalmierPro/Utilities/CLILocator.swift`
- Test: `Tests/PalmierProTests/CLI/CLILocatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/CLI/CLILocatorTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("CLILocator")
struct CLILocatorTests {

    @Test func overrideWinsWhenExecutable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("mytool")
        FileManager.default.createFile(atPath: fake.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])

        let locator = CLILocator(tool: "mytool", searchDirs: [], shellResolver: { nil })
        #expect(locator.resolve(override: fake.path) == fake.path)
    }

    @Test func findsToolInSearchDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("mytool")
        FileManager.default.createFile(atPath: fake.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])

        let locator = CLILocator(tool: "mytool", searchDirs: [dir.path], shellResolver: { nil })
        #expect(locator.resolve(override: nil) == fake.path)
    }

    @Test func fallsBackToShellResolver() {
        let locator = CLILocator(tool: "mytool", searchDirs: [],
                                 shellResolver: { "/somewhere/mytool" })
        #expect(locator.resolve(override: nil) == "/somewhere/mytool")
    }

    @Test func returnsNilWhenMissing() {
        let locator = CLILocator(tool: "nope", searchDirs: [], shellResolver: { nil })
        #expect(locator.resolve(override: nil) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CLILocator`
Expected: FAIL — `CLILocator` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Utilities/CLILocator.swift
import Foundation

/// Resolves an absolute path to a CLI tool. A GUI app launched from Finder has a
/// minimal PATH, so we probe common install dirs and fall back to a login shell.
struct CLILocator {
    let tool: String
    let searchDirs: [String]
    let shellResolver: () -> String?

    static let defaultSearchDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.claude/local",
    ]

    init(tool: String,
         searchDirs: [String] = CLILocator.defaultSearchDirs,
         shellResolver: (() -> String?)? = nil) {
        self.tool = tool
        self.searchDirs = searchDirs
        self.shellResolver = shellResolver ?? { CLILocator.loginShellWhich(tool) }
    }

    /// Returns the first usable absolute path, or nil.
    func resolve(override: String?) -> String? {
        if let override, isExecutable(override) { return override }
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if isExecutable(candidate) { return candidate }
        }
        if let viaShell = shellResolver(), isExecutable(viaShell) { return viaShell }
        return nil
    }

    private func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    static func loginShellWhich(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CLILocator`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Utilities/CLILocator.swift Tests/PalmierProTests/CLI/CLILocatorTests.swift
git commit -m "feat: add CLILocator for resolving CLI tool paths"
```

---

### Task 2: CLIProcess async runner

**Files:**
- Create: `Sources/PalmierPro/Utilities/CLIProcess.swift`

No unit test (it spawns processes; covered by manual/integration use). Keep it small and obviously correct.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/PalmierPro/Utilities/CLIProcess.swift
import Foundation

enum CLIProcessError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "Could not launch CLI: \(m)"
        case .nonZeroExit(let code, let stderr):
            return stderr.isEmpty ? "CLI exited with code \(code)" : stderr
        case .timedOut: return "CLI timed out."
        }
    }
}

/// Thin async wrapper over Process. Streams stdout as lines; captures stderr.
struct CLIProcess {
    let executable: String
    let arguments: [String]
    var environment: [String: String]? = nil
    var timeout: TimeInterval = 600

    /// Runs to completion and returns full stdout. Throws on non-zero exit or timeout.
    func runCapturing() async throws -> String {
        var out = ""
        for try await line in streamLines() { out += line + "\n" }
        return out
    }

    /// Streams stdout line by line. Throws `nonZeroExit` (with stderr) if the process fails.
    func streamLines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stderrData = LockedData()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stderrData.append(chunk) }
            }

            var buffer = Data()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    continuation.yield(String(decoding: lineData, as: UTF8.self))
                }
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                if !buffer.isEmpty {
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                }
                let stderrText = String(decoding: stderrData.snapshot(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: CLIProcessError.nonZeroExit(
                        code: proc.terminationStatus, stderr: stderrText))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: CLIProcessError.launchFailed(error.localizedDescription))
                return
            }

            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    process.terminate()
                    continuation.finish(throwing: CLIProcessError.timedOut)
                }
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning { process.terminate() }
            }
        }
    }
}

/// Tiny thread-safe Data accumulator for the stderr readability handler.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Utilities/CLIProcess.swift
git commit -m "feat: add CLIProcess async process runner"
```

---

## Phase 1 — Claude Code CLI chat backend

### Task 3: ChatBackend preference + selection

**Files:**
- Create: `Sources/PalmierPro/Agent/ChatBackend.swift`
- Test: `Tests/PalmierProTests/CLI/ChatBackendTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/CLI/ChatBackendTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("ChatBackend")
struct ChatBackendTests {

    @Test func effectiveUsesSelectedWhenAvailable() {
        let avail: Set<ChatBackend> = [.apiKey, .palmier, .claudeCLI]
        #expect(ChatBackend.effective(selected: .claudeCLI, available: avail) == .claudeCLI)
    }

    @Test func effectiveFallsBackWhenSelectedUnavailable() {
        let avail: Set<ChatBackend> = [.palmier]
        #expect(ChatBackend.effective(selected: .claudeCLI, available: avail) == .palmier)
    }

    @Test func effectiveIsNilWhenNothingAvailable() {
        #expect(ChatBackend.effective(selected: .apiKey, available: []) == nil)
    }

    @Test func fallbackOrderPrefersApiKeyThenPalmierThenCLI() {
        #expect(ChatBackend.effective(selected: .palmier,
                                      available: [.apiKey, .claudeCLI]) == .apiKey)
        #expect(ChatBackend.effective(selected: .palmier,
                                      available: [.claudeCLI]) == .claudeCLI)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChatBackend`
Expected: FAIL — `ChatBackend` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Agent/ChatBackend.swift
import Foundation

enum ChatBackend: String, CaseIterable, Sendable {
    case palmier
    case apiKey
    case claudeCLI

    var displayName: String {
        switch self {
        case .palmier: "Palmier (sign in)"
        case .apiKey: "Anthropic API key"
        case .claudeCLI: "Claude Code CLI"
        }
    }

    private static let key = "io.palmier.pro.chat.backend"

    static var selected: ChatBackend {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let b = ChatBackend(rawValue: raw) { return b }
            return .palmier
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Resolve the effective backend: the selected one if available, else the first
    /// available in priority order (apiKey, palmier, claudeCLI). Nil if none available.
    static func effective(selected: ChatBackend, available: Set<ChatBackend>) -> ChatBackend? {
        if available.contains(selected) { return selected }
        for candidate in [ChatBackend.apiKey, .palmier, .claudeCLI] where available.contains(candidate) {
            return candidate
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ChatBackend`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/ChatBackend.swift Tests/PalmierProTests/CLI/ChatBackendTests.swift
git commit -m "feat: add ChatBackend preference and selection logic"
```

---

### Task 4: PalmierMCPConfig (inline config + registration)

**Files:**
- Create: `Sources/PalmierPro/Agent/Clients/ClaudeCLI/PalmierMCPConfig.swift`

- [ ] **Step 1: Write the implementation**

```swift
// Sources/PalmierPro/Agent/Clients/ClaudeCLI/PalmierMCPConfig.swift
import Foundation

/// Wires the Palmier MCP server into the Claude CLI two ways:
/// 1. An inline --mcp-config JSON used by the app's own `claude -p` invocations (scoped,
///    no permission prompts, always correct port).
/// 2. A one-time `claude mcp add` so the user's interactive terminal also sees Palmier.
enum PalmierMCPConfig {

    static var endpoint: String { "http://127.0.0.1:\(MCPService.port)/mcp" }

    static let serverName = "palmier-pro"

    /// Tool allowlist pattern that pre-authorizes every Palmier MCP tool in -p mode.
    static let allowedToolsPattern = "mcp__palmier-pro__*"

    /// JSON string for `--mcp-config`.
    static func inlineConfigJSON() -> String {
        let dict: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "type": "http",
                    "url": endpoint,
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static let registeredKey = "io.palmier.pro.chat.cli.mcpRegistered"

    /// Idempotently runs `claude mcp add …`. Non-fatal on failure.
    static func registerIfNeeded(claudePath: String) async {
        guard !UserDefaults.standard.bool(forKey: registeredKey) else { return }
        let proc = CLIProcess(
            executable: claudePath,
            arguments: ["mcp", "add", "--transport", "http", serverName, endpoint],
            timeout: 30
        )
        do {
            _ = try await proc.runCapturing()
            UserDefaults.standard.set(true, forKey: registeredKey)
            Log.mcp.notice("registered palmier-pro MCP with claude CLI")
        } catch {
            // Already-exists or transient failure — the inline config covers our own calls.
            Log.mcp.notice("claude mcp add skipped: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly (uses existing `MCPService.port` and `Log.mcp`).

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/ClaudeCLI/PalmierMCPConfig.swift
git commit -m "feat: add PalmierMCPConfig for Claude CLI MCP wiring"
```

---

### Task 5: Claude stream-json parser

**Files:**
- Create: `Sources/PalmierPro/Agent/Clients/ClaudeCLI/ClaudeStreamJSONParser.swift`
- Test: `Tests/PalmierProTests/CLI/ClaudeStreamJSONParserTests.swift`

Background: `claude -p --output-format stream-json --verbose` emits one JSON object per line:
- `{"type":"system","subtype":"init","session_id":"…"}`
- `{"type":"assistant","message":{"content":[{"type":"text","text":"…"}]}}`
- `{"type":"assistant","message":{"content":[{"type":"tool_use","id":"…","name":"…","input":{…}}]}}`
- `{"type":"user","message":{"content":[{"type":"tool_result",…}]}}` (CLI ran the tool)
- `{"type":"result","subtype":"success","session_id":"…","result":"…"}`

The parser converts a sequence of lines into `AnthropicStreamEvent`s and captures the session id. tool_use blocks are surfaced as `.toolUseComplete` (informational only — the app does NOT execute them).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/CLI/ClaudeStreamJSONParserTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("ClaudeStreamJSONParser")
struct ClaudeStreamJSONParserTests {

    private func events(_ lines: [String]) -> ([AnthropicStreamEvent], String?) {
        var parser = ClaudeStreamJSONParser()
        var out: [AnthropicStreamEvent] = []
        for line in lines { out.append(contentsOf: parser.consume(line: line)) }
        return (out, parser.sessionId)
    }

    @Test func capturesSessionIdFromInit() {
        let (_, sid) = events([
            #"{"type":"system","subtype":"init","session_id":"abc-123"}"#
        ])
        #expect(sid == "abc-123")
    }

    @Test func emitsTextDeltaForAssistantText() {
        let (evts, _) = events([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#
        ])
        guard case .textDelta(let t)? = evts.first else {
            Issue.record("expected textDelta"); return
        }
        #expect(t == "Hello")
    }

    @Test func emitsToolUseComplete() {
        let (evts, _) = events([
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__palmier-pro__add_clips","input":{"x":1}}]}}"#
        ])
        guard case .toolUseComplete(let id, let name, let json)? = evts.first else {
            Issue.record("expected toolUseComplete"); return
        }
        #expect(id == "t1")
        #expect(name == "mcp__palmier-pro__add_clips")
        #expect(json.contains("\"x\""))
    }

    @Test func emitsMessageStopOnResult() {
        let (evts, sid) = events([
            #"{"type":"result","subtype":"success","session_id":"s9","result":"done"}"#
        ])
        guard case .messageStop(let reason)? = evts.last else {
            Issue.record("expected messageStop"); return
        }
        #expect(reason == .endTurn)
        #expect(sid == "s9")
    }

    @Test func ignoresBlankAndNonJSONLines() {
        let (evts, _) = events(["", "not json", "   "])
        #expect(evts.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeStreamJSONParser`
Expected: FAIL — `ClaudeStreamJSONParser` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Agent/Clients/ClaudeCLI/ClaudeStreamJSONParser.swift
import Foundation

/// Incremental parser for `claude --output-format stream-json` lines.
/// Stateless except for the captured session id.
struct ClaudeStreamJSONParser {
    private(set) var sessionId: String?

    mutating func consume(line: String) -> [AnthropicStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        if let sid = obj["session_id"] as? String { sessionId = sid }

        switch type {
        case "assistant":
            return assistantEvents(obj)
        case "result":
            return [.messageStop(stopReason: .endTurn)]
        default:
            return []
        }
    }

    private func assistantEvents(_ obj: [String: Any]) -> [AnthropicStreamEvent] {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        var events: [AnthropicStreamEvent] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    events.append(.textDelta(text))
                }
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                let json = (try? JSONSerialization.data(withJSONObject: input))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                events.append(.toolUseComplete(id: id, name: name, inputJSON: json))
            default:
                break
            }
        }
        return events
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeStreamJSONParser`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/ClaudeCLI/ClaudeStreamJSONParser.swift Tests/PalmierProTests/CLI/ClaudeStreamJSONParserTests.swift
git commit -m "feat: add Claude stream-json parser"
```

---

### Task 6: ClaudeCLIRunner + AgentService integration

**Files:**
- Create: `Sources/PalmierPro/Agent/Clients/ClaudeCLI/ClaudeCLIRunner.swift`
- Modify: `Sources/PalmierPro/Agent/ChatSessionStore.swift` (add `cliSessionId`)
- Modify: `Sources/PalmierPro/Agent/AgentService.swift` (selection + `runCLITurn`)

- [ ] **Step 1: Add `cliSessionId` to ChatSession**

In `Sources/PalmierPro/Agent/ChatSessionStore.swift`, add the stored property, init param, coding key, and decode line. Final struct:

```swift
struct ChatSession: Codable, Identifiable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var messages: [AgentMessage]
    var isOpen: Bool
    var cliSessionId: String?

    init(id: UUID = UUID(), title: String = "New chat", messages: [AgentMessage] = [], isOpen: Bool = true, cliSessionId: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = Date()
        self.messages = messages
        self.isOpen = isOpen
        self.cliSessionId = cliSessionId
    }

    private enum CodingKeys: String, CodingKey { case id, title, updatedAt, messages, isOpen, cliSessionId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messages = try c.decode([AgentMessage].self, forKey: .messages)
        self.isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
        self.cliSessionId = try c.decodeIfPresent(String.self, forKey: .cliSessionId)
    }
}
```

- [ ] **Step 2: Build to confirm ChatSession change compiles**

Run: `swift build`
Expected: builds cleanly (the encoder is synthesized; the explicit decoder now reads `cliSessionId`).

- [ ] **Step 3: Write ClaudeCLIRunner**

```swift
// Sources/PalmierPro/Agent/Clients/ClaudeCLI/ClaudeCLIRunner.swift
import Foundation

/// Drives a single chat turn through the Claude Code CLI. The CLI runs the full
/// agentic loop itself, calling Palmier MCP tools that mutate the live editor.
struct ClaudeCLIRunner {
    let claudePath: String
    let model: AnthropicModel
    let systemPrompt: String

    /// CLI model alias for `--model`.
    static func alias(for model: AnthropicModel) -> String {
        switch model {
        case .opus47: "opus"
        case .sonnet46: "sonnet"
        case .haiku45: "haiku"
        }
    }

    struct TurnResult: Sendable {
        var sessionId: String?
    }

    /// Streams events for one user turn. `resumeSessionId` continues a prior CLI session.
    /// The returned closure-free stream finishes when the CLI exits.
    func stream(
        userText: String,
        resumeSessionId: String?,
        onSessionId: @escaping @Sendable (String) -> Void
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        var args = [
            "-p", userText,
            "--output-format", "stream-json",
            "--verbose",
            "--model", Self.alias(for: model),
            "--mcp-config", PalmierMCPConfig.inlineConfigJSON(),
            "--strict-mcp-config",
            "--allowedTools", PalmierMCPConfig.allowedToolsPattern,
            "--append-system-prompt", systemPrompt,
        ]
        if let resumeSessionId {
            args.append(contentsOf: ["--resume", resumeSessionId])
        }

        let proc = CLIProcess(executable: claudePath, arguments: args)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = ClaudeStreamJSONParser()
                do {
                    for try await line in proc.streamLines() {
                        for event in parser.consume(line: line) { continuation.yield(event) }
                    }
                    if let sid = parser.sessionId { onSessionId(sid) }
                    continuation.finish()
                } catch {
                    if let sid = parser.sessionId { onSessionId(sid) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: Wire AgentService — availability, selection, models**

In `Sources/PalmierPro/Agent/AgentService.swift`:

(a) Add a cached locator + path near the top of the class:

```swift
    private static let claudeLocator = CLILocator(tool: "claude")
    private var claudePath: String? { Self.claudeLocator.resolve(override: nil) }
    var isClaudeCLIAvailable: Bool { claudePath != nil }
```

(b) Replace `availableBackends`/`canStream`/`availableModels`/`selectClient` logic. Add:

```swift
    var availableBackends: Set<ChatBackend> {
        var set: Set<ChatBackend> = []
        if hasApiKey { set.insert(.apiKey) }
        let account = AccountService.shared
        if account.isSignedIn && account.hasCredits { set.insert(.palmier) }
        if isClaudeCLIAvailable { set.insert(.claudeCLI) }
        return set
    }

    var effectiveBackend: ChatBackend? {
        ChatBackend.effective(selected: ChatBackend.selected, available: availableBackends)
    }
```

Change `canStream`:

```swift
    var canStream: Bool { effectiveBackend != nil }
```

Change `availableModels` so the CLI backend offers all three aliases:

```swift
    var availableModels: [AnthropicModel] {
        switch effectiveBackend {
        case .apiKey, .claudeCLI: return AnthropicModel.allCases
        case .palmier: return AccountService.shared.isPaid ? [.sonnet46] : [.haiku45]
        case .none: return [.sonnet46]
        }
    }
```

(c) Update `send(...)`'s guard message to mention the CLI option:

```swift
        guard canStream else {
            streamError = .upstream("Sign in, add an Anthropic API key, or install the Claude Code CLI to start.")
            return
        }
```

- [ ] **Step 5: Wire AgentService — branch the turn runner**

In `kickOffStream()` (or at the top of the streaming task), branch on backend. Replace the body of the streaming task to choose the runner:

```swift
    private func kickOffStream() {
        currentTask?.cancel()
        isStreaming = true
        currentTask = Task { [weak self] in
            defer {
                self?.isStreaming = false
                self?.syncMessagesIntoCurrentSession()
                self?.onSessionsChanged?()
            }
            if self?.effectiveBackend == .claudeCLI {
                await self?.runCLITurn()
            } else {
                await self?.runLoop()
            }
        }
    }
```

Add `runCLITurn()`:

```swift
    private func runCLITurn() async {
        guard let claudePath else {
            streamError = .upstream("Claude Code CLI not found. Install it or set its path in Settings.")
            return
        }
        guard AppState.shared.mcpService?.isRunning ?? false else {
            AppState.shared.startMCPService()
            if AppState.shared.mcpService?.isRunning != true {
                streamError = .upstream("Enable the MCP server in Settings to use the Claude Code CLI backend.")
                return
            }
            return await runCLITurn()
        }

        await PalmierMCPConfig.registerIfNeeded(claudePath: claudePath)

        // The latest user message is what we send; the CLI keeps prior context via --resume.
        guard let userText = messages.last(where: { $0.role == .user })
            .flatMap(Self.plainText) else { return }

        let runner = ClaudeCLIRunner(
            claudePath: claudePath,
            model: effectiveModel,
            systemPrompt: AgentInstructions.serverInstructions
        )
        let resume = currentSessionId
            .flatMap { id in sessions.first { $0.id == id }?.cliSessionId }

        let assistant = AgentMessage(role: .assistant, blocks: [])
        messages.append(assistant)
        let assistantID = assistant.id

        do {
            let stream = runner.stream(userText: userText, resumeSessionId: resume) { [weak self] sid in
                Task { @MainActor in self?.storeCLISessionId(sid) }
            }
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let chunk):
                    appendTextDelta(chunk, toAssistant: assistantID)
                case .toolUseComplete(let id, let name, let inputJSON):
                    appendToolUse(id: id, name: name, inputJSON: inputJSON, toAssistant: assistantID)
                case .messageStop:
                    break
                }
            }
            dropEmptyAssistantTurn(id: assistantID)
        } catch is CancellationError {
            dropEmptyAssistantTurn(id: assistantID)
        } catch {
            dropEmptyAssistantTurn(id: assistantID)
            streamError = .upstream(error.localizedDescription)
        }
    }

    private func storeCLISessionId(_ sid: String) {
        guard let id = currentSessionId,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].cliSessionId = sid
    }

    private static func plainText(_ message: AgentMessage) -> String? {
        for block in message.blocks {
            if case let .text(s) = block, !s.isEmpty { return s }
        }
        return nil
    }
```

Note: the CLI path appends `tool_use` blocks to the assistant message for display only. Because these turns never set `stopReason == .toolUse` in the app loop, the app never executes them. The MCP server applies the edits as the CLI calls them.

- [ ] **Step 6: Build**

Run: `swift build`
Expected: builds cleanly. Verify `selectClient()` is still used only by `runLoop()` (non-CLI path); leave it unchanged.

- [ ] **Step 7: Manual smoke test (CLI required, can't be unit-tested)**

1. `swift run`, open a project, open the agent panel.
2. Settings → Agent → set backend to "Claude Code CLI" (Task 7 adds this UI; until then, set the default via `defaults write` is not needed — test after Task 7).
3. Send "add a 3 second black title clip". Confirm the timeline mutates and assistant text streams.

- [ ] **Step 8: Commit**

```bash
git add Sources/PalmierPro/Agent/Clients/ClaudeCLI/ClaudeCLIRunner.swift Sources/PalmierPro/Agent/ChatSessionStore.swift Sources/PalmierPro/Agent/AgentService.swift
git commit -m "feat: add Claude Code CLI chat backend turn runner"
```

---

### Task 7: AgentPane backend picker + CLI status

**Files:**
- Modify: `Sources/PalmierPro/Settings/AgentPane.swift`

- [ ] **Step 1: Add a backend picker section above the API-key section**

Add state and a picker. Insert into `body` before `apiKeySection`:

```swift
    @State private var backend: ChatBackend = ChatBackend.selected
    private let agentService: AgentService  // injected; see Step 2
```

New section view:

```swift
    private var backendSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Chat Backend")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Picker("", selection: $backend) {
                ForEach(ChatBackend.allCases, id: \.self) { b in
                    Text(b.displayName).tag(b)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: backend) { _, newValue in ChatBackend.selected = newValue }

            if backend == .claudeCLI {
                claudeCLIStatusRow
            }
        }
    }

    private var claudeCLIStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(agentService.isClaudeCLIAvailable ? Color.green : AppTheme.Text.mutedColor)
                .frame(width: 8, height: 8)
            Text(agentService.isClaudeCLIAvailable
                 ? "claude found — uses your Claude Code subscription"
                 : "claude not found on PATH")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(AppTheme.Opacity.muted)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
    }
```

Update `body`:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            backendSection
            Divider().overlay(AppTheme.Border.subtleColor)
            apiKeySection
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
        }
        .onAppear(perform: refresh)
    }
```

- [ ] **Step 2: Provide the AgentService to AgentPane**

`AgentPane` needs the live `AgentService` for `isClaudeCLIAvailable`. Find where `AgentPane()` is constructed (in `SettingsView.swift`) and pass the editor's `agentService`. If Settings has no editor handle, add a lightweight initializer that resolves it from `AppState.shared.activeProject?.editorViewModel.agentService` with a fallback:

```swift
    init(agentService: AgentService? = nil) {
        self.agentService = agentService
            ?? AppState.shared.activeProject?.editorViewModel.agentService
            ?? AgentService()
    }
```

Verify the property name: confirm `EditorViewModel` exposes `agentService` (search: `grep -n "agentService" Sources/PalmierPro/Editor/ViewModel/EditorViewModel.swift`). If the property has a different name, use that.

- [ ] **Step 3: Build and visually verify**

Run: `swift build` then `swift run`.
Open Settings → Agent. Expected: a segmented "Chat Backend" picker; selecting "Claude Code CLI" shows a green status row when `claude` is installed.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Settings/AgentPane.swift Sources/PalmierPro/Settings/SettingsView.swift
git commit -m "feat: add chat backend picker and Claude CLI status to settings"
```

---

## Phase 2 — Higgsfield CLI generation provider

### Task 8: GenerationProvider preference + auth status

**Files:**
- Create: `Sources/PalmierPro/Generation/Higgsfield/GenerationProvider.swift`

- [ ] **Step 1: Write the implementation**

```swift
// Sources/PalmierPro/Generation/Higgsfield/GenerationProvider.swift
import Foundation

enum GenerationProvider: String, CaseIterable, Sendable {
    case palmier
    case higgsfield

    var displayName: String {
        switch self {
        case .palmier: "Palmier"
        case .higgsfield: "Higgsfield (CLI)"
        }
    }

    private static let key = "io.palmier.pro.generation.provider"

    static var selected: GenerationProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let p = GenerationProvider(rawValue: raw) { return p }
            return .palmier
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Locates the higgsfield binary and reports login state.
enum HiggsfieldCLI {
    static let locator = CLILocator(tool: "higgsfield")

    static var path: String? { locator.resolve(override: nil) }
    static var isAvailable: Bool { path != nil }

    /// Returns true if `higgsfield auth token` prints a token.
    static func isLoggedIn() async -> Bool {
        guard let path else { return false }
        let proc = CLIProcess(executable: path, arguments: ["auth", "token"], timeout: 15)
        let out = (try? await proc.runCapturing())?.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(out ?? "").isEmpty
    }

    /// Launches the browser device-login flow.
    static func login() async throws {
        guard let path else { throw CLIProcessError.launchFailed("higgsfield not found") }
        _ = try await CLIProcess(executable: path, arguments: ["auth", "login"], timeout: 300).runCapturing()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Generation/Higgsfield/GenerationProvider.swift
git commit -m "feat: add GenerationProvider preference and HiggsfieldCLI helpers"
```

---

### Task 9: Higgsfield command builder

**Files:**
- Create: `Sources/PalmierPro/Generation/Higgsfield/HiggsfieldCommand.swift`
- Test: `Tests/PalmierProTests/Generation/HiggsfieldCommandTests.swift`

The builder turns a `GenerationInput`, a clip type, and the local reference file paths into the exact `higgsfield generate create …` argv. Local paths are passed directly (the CLI auto-uploads them).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Generation/HiggsfieldCommandTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("HiggsfieldCommand")
struct HiggsfieldCommandTests {

    private func input(model: String = "nano_banana_2") -> GenerationInput {
        GenerationInput(prompt: "a cat", model: model, duration: 5, aspectRatio: "16:9", resolution: "1080p")
    }

    @Test func imageArgsIncludePromptModelAspectAndJSON() {
        let argv = HiggsfieldCommand.argv(
            genInput: input(), assetType: .image, referencePaths: [], numImages: 1)
        #expect(argv.first == "generate")
        #expect(argv.contains("create"))
        #expect(argv.contains("nano_banana_2"))
        #expect(adjacent(argv, "--prompt", "a cat"))
        #expect(adjacent(argv, "--aspect_ratio", "16:9"))
        #expect(argv.contains("--wait"))
        #expect(argv.contains("--json"))
    }

    @Test func imageReferencesBecomeImageFlags() {
        let argv = HiggsfieldCommand.argv(
            genInput: input(), assetType: .image,
            referencePaths: ["/tmp/a.png", "/tmp/b.png"], numImages: 1)
        #expect(occurrences(argv, of: "--image") == 2)
        #expect(adjacent(argv, "--image", "/tmp/a.png"))
        #expect(adjacent(argv, "--image", "/tmp/b.png"))
    }

    @Test func videoUsesStartImageForFirstReference() {
        let argv = HiggsfieldCommand.argv(
            genInput: input(model: "seedance"), assetType: .video,
            referencePaths: ["/tmp/first.png"], numImages: 1)
        #expect(adjacent(argv, "--start-image", "/tmp/first.png"))
    }

    @Test func resolutionOmittedWhenNil() {
        var gi = input(); gi.resolution = nil
        let argv = HiggsfieldCommand.argv(
            genInput: gi, assetType: .image, referencePaths: [], numImages: 1)
        #expect(!argv.contains("--resolution"))
    }

    // helpers
    private func adjacent(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        for i in argv.indices where argv[i] == flag {
            if i + 1 < argv.count && argv[i + 1] == value { return true }
        }
        return false
    }
    private func occurrences(_ argv: [String], of flag: String) -> Int {
        argv.filter { $0 == flag }.count
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HiggsfieldCommand`
Expected: FAIL — `HiggsfieldCommand` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Generation/Higgsfield/HiggsfieldCommand.swift
import Foundation

/// Builds `higgsfield generate create …` argv from a generation request.
/// Reference paths are local files; the CLI auto-uploads them.
enum HiggsfieldCommand {
    static func argv(
        genInput: GenerationInput,
        assetType: ClipType,
        referencePaths: [String],
        numImages: Int
    ) -> [String] {
        var argv = ["generate", "create", genInput.model,
                    "--prompt", genInput.prompt,
                    "--aspect_ratio", genInput.aspectRatio]
        if let resolution = genInput.resolution {
            argv.append(contentsOf: ["--resolution", resolution])
        }

        switch assetType {
        case .image:
            for path in referencePaths { argv.append(contentsOf: ["--image", path]) }
        case .video:
            // First ref is the start frame; a second (optional) is the end frame.
            if let first = referencePaths.first {
                argv.append(contentsOf: ["--start-image", first])
            }
            if referencePaths.count > 1 {
                argv.append(contentsOf: ["--end-image", referencePaths[1]])
            }
        case .audio:
            for path in referencePaths { argv.append(contentsOf: ["--audio", path]) }
        case .text, .lottie:
            break
        }

        argv.append(contentsOf: ["--wait", "--json"])
        return argv
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HiggsfieldCommand`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Generation/Higgsfield/HiggsfieldCommand.swift Tests/PalmierProTests/Generation/HiggsfieldCommandTests.swift
git commit -m "feat: add Higgsfield command builder"
```

---

### Task 10: Higgsfield result parser + guard

**Files:**
- Create: `Sources/PalmierPro/Generation/Higgsfield/HiggsfieldResult.swift`
- Test: `Tests/PalmierProTests/Generation/HiggsfieldResultTests.swift`

`higgsfield generate create … --wait --json` prints JSON when done. The result URL(s) may appear under a few keys depending on model; parse defensively. Carry over the astronaut "result-is-input" guard.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Generation/HiggsfieldResultTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("HiggsfieldResult")
struct HiggsfieldResultTests {

    @Test func parsesCdnUrl() throws {
        let json = #"{"cdn_url":"https://cdn.higgsfield.ai/out/abc.jpg"}"#
        let urls = try HiggsfieldResult.resultURLs(fromJSON: json)
        #expect(urls == ["https://cdn.higgsfield.ai/out/abc.jpg"])
    }

    @Test func parsesResultsArray() throws {
        let json = #"{"results":[{"url":"https://x/1.mp4"},{"url":"https://x/2.mp4"}]}"#
        let urls = try HiggsfieldResult.resultURLs(fromJSON: json)
        #expect(urls == ["https://x/1.mp4", "https://x/2.mp4"])
    }

    @Test func throwsWhenNoURL() {
        #expect(throws: (any Error).self) {
            _ = try HiggsfieldResult.resultURLs(fromJSON: #"{"status":"ok"}"#)
        }
    }

    @Test func detectsResultIsInput() {
        let url = "https://cdn.higgsfield.ai/abcd1234_resize.jpg"
        #expect(HiggsfieldResult.isInputReference(url, inputUUIDs: ["abcd1234"]))
        #expect(!HiggsfieldResult.isInputReference(url, inputUUIDs: ["zzzz"]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HiggsfieldResult`
Expected: FAIL — `HiggsfieldResult` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Generation/Higgsfield/HiggsfieldResult.swift
import Foundation

enum HiggsfieldResultError: LocalizedError {
    case noURL(String)
    var errorDescription: String? {
        switch self {
        case .noURL(let raw): return "No result URL in Higgsfield output: \(raw.prefix(200))"
        }
    }
}

enum HiggsfieldResult {
    /// Extracts result URLs from `--json` output. Tolerates several shapes.
    static func resultURLs(fromJSON json: String) throws -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw HiggsfieldResultError.noURL(json)
        }

        if let dict = obj as? [String: Any] {
            if let single = dict["cdn_url"] as? String { return [single] }
            if let urls = dict["urls"] as? [String], !urls.isEmpty { return urls }
            if let results = dict["results"] as? [[String: Any]] {
                let urls = results.compactMap { $0["url"] as? String ?? $0["cdn_url"] as? String }
                if !urls.isEmpty { return urls }
            }
            if let url = dict["url"] as? String { return [url] }
        }
        throw HiggsfieldResultError.noURL(json)
    }

    private static let resizeSuffix = try! NSRegularExpression(pattern: #"/([0-9a-f]+)_resize\.jpg$"#)

    /// True if the CDN URL is one of the input references (the recurring Higgsfield bug).
    static func isInputReference(_ cdnURL: String, inputUUIDs: [String]) -> Bool {
        let range = NSRange(cdnURL.startIndex..., in: cdnURL)
        guard let match = resizeSuffix.firstMatch(in: cdnURL, range: range),
              let r = Range(match.range(at: 1), in: cdnURL) else { return false }
        return inputUUIDs.contains(String(cdnURL[r]))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HiggsfieldResult`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Generation/Higgsfield/HiggsfieldResult.swift Tests/PalmierProTests/Generation/HiggsfieldResultTests.swift
git commit -m "feat: add Higgsfield result parser with result-is-input guard"
```

---

### Task 11: HiggsfieldGenerationProvider + route in GenerationService

**Files:**
- Create: `Sources/PalmierPro/Generation/Higgsfield/HiggsfieldGenerationProvider.swift`
- Modify: `Sources/PalmierPro/Generation/GenerationService.swift`

- [ ] **Step 1: Write HiggsfieldGenerationProvider**

```swift
// Sources/PalmierPro/Generation/Higgsfield/HiggsfieldGenerationProvider.swift
import Foundation

/// Runs one generation via the higgsfield CLI and returns result URL(s).
struct HiggsfieldGenerationProvider {

    enum ProviderError: LocalizedError {
        case notInstalled
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Higgsfield CLI not found. Install it or sign in with `higgsfield auth login`."
            }
        }
    }

    /// Generate and return result URL strings. Retries once on the result-is-input bug.
    static func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        referencePaths: [String],
        numImages: Int
    ) async throws -> [String] {
        guard let path = HiggsfieldCLI.path else { throw ProviderError.notInstalled }
        let argv = HiggsfieldCommand.argv(
            genInput: genInput, assetType: assetType,
            referencePaths: referencePaths, numImages: numImages)

        for attempt in 0..<2 {
            let out = try await CLIProcess(executable: path, arguments: argv).runCapturing()
            let lastJSON = out.split(separator: "\n").last.map(String.init) ?? out
            let urls = try HiggsfieldResult.resultURLs(fromJSON: lastJSON)
            let inputUUIDs = referencePaths.map { ($0 as NSString).lastPathComponent }
            if attempt == 0, let first = urls.first,
               HiggsfieldResult.isInputReference(first, inputUUIDs: inputUUIDs) {
                Log.generation.notice("higgsfield returned input ref; retrying")
                continue
            }
            return urls
        }
        return []
    }
}
```

- [ ] **Step 2: Route the upload step in `GenerationService.generate`**

In `generate(...)`, the block that computes `uploaded` calls `uploadReferences(...)`. Skip Convex upload for the Higgsfield provider — pass local file paths through instead. Wrap the existing else-branch:

Find (inside `generate`, the `else` of `if let preUploadedURLs`):

```swift
                } else {
                    var urlsToUpload = refURLs
                    // … existing trim/preprocess/cacheKeys logic …
                    uploaded = try await uploadReferences(
                        at: urlsToUpload,
                        types: refTypes,
                        cacheKeys: cacheKeys,
                    )
                }
```

Change the final assignment so Higgsfield uses local paths (keep all the trim/preprocess rewriting, which produces local file URLs):

```swift
                    if GenerationProvider.selected == .higgsfield {
                        uploaded = urlsToUpload.map(\.path)
                    } else {
                        uploaded = try await uploadReferences(
                            at: urlsToUpload,
                            types: refTypes,
                            cacheKeys: cacheKeys,
                        )
                    }
```

(For Higgsfield, `uploaded` now holds local file paths; `finalGenInput.imageURLs` will carry them, which is fine — they are only used to build argv and for logging.)

- [ ] **Step 3: Route `runJob` by provider**

At the top of `runJob(...)`, branch before the Convex `submit`:

```swift
        if GenerationProvider.selected == .higgsfield {
            await runHiggsfieldJob(
                placeholders: placeholders, genInput: genInput,
                editor: editor, onComplete: onComplete, onFailure: onFailure)
            return
        }
```

Add the Higgsfield job runner that reuses `downloadAndFinalize`/`finalizeSuccess` shape:

```swift
    private func runHiggsfieldJob(
        placeholders: [MediaAsset],
        genInput: GenerationInput,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        let assetType = placeholders.first?.type ?? .image
        let referencePaths = genInput.imageURLs ?? []
        do {
            let urlStrings = try await HiggsfieldGenerationProvider.generate(
                genInput: genInput, assetType: assetType,
                referencePaths: referencePaths, numImages: placeholders.count)
            let job = BackendGenerationJob(
                _id: "higgsfield", status: .succeeded,
                resultUrls: urlStrings, errorMessage: nil,
                costCredits: nil, completedAt: nil)
            await finalizeSuccess(job: job, placeholders: placeholders, editor: editor,
                                  onComplete: onComplete, onFailure: onFailure)
        } catch {
            let message = error.localizedDescription
            Log.generation.error("higgsfield generate failed: \(message)")
            for placeholder in placeholders { placeholder.generationStatus = .failed(message) }
            onFailure?()
        }
    }
```

Verify `BackendGenerationJob`'s memberwise init is accessible from this file (same module — it is). If `BackendGenerationJob` is `Decodable`-only with no explicit init, the synthesized memberwise init exists because it has no custom init; confirm by building.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 5: Manual smoke test (CLI + login required)**

1. `higgsfield auth login` in a terminal.
2. `swift run`, Settings → Models → provider "Higgsfield" (Task 13 UI). Until then, test after Task 13.
3. Generate an image from a prompt; confirm it downloads into the project and appears in the media panel.

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Generation/Higgsfield/HiggsfieldGenerationProvider.swift Sources/PalmierPro/Generation/GenerationService.swift
git commit -m "feat: route generation through Higgsfield CLI provider"
```

---

### Task 12: HiggsfieldCatalog

**Files:**
- Create: `Sources/PalmierPro/Generation/Higgsfield/HiggsfieldCatalog.swift`

Higgsfield model IDs differ from Palmier's. Fetch them from `higgsfield model list --image/--video --json` and cache. v1 exposes id + display name + kind so the model picker can list them; param surfaces reuse the generic generation UI defaults.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/PalmierPro/Generation/Higgsfield/HiggsfieldCatalog.swift
import Foundation

struct HiggsfieldModel: Identifiable, Sendable, Equatable {
    let id: String          // e.g. "nano_banana_2"
    let displayName: String
    let kind: Kind
    enum Kind: Sendable { case image, video }
}

@Observable
@MainActor
final class HiggsfieldCatalog {
    static let shared = HiggsfieldCatalog()
    private init() {}

    private(set) var image: [HiggsfieldModel] = []
    private(set) var video: [HiggsfieldModel] = []
    private(set) var isLoaded = false
    private(set) var lastError: String?

    func refresh() async {
        guard let path = HiggsfieldCLI.path else {
            lastError = "Higgsfield CLI not found"; return
        }
        async let img = Self.fetch(path: path, kindFlag: "--image", kind: .image)
        async let vid = Self.fetch(path: path, kindFlag: "--video", kind: .video)
        let (i, v) = await (img, vid)
        self.image = i
        self.video = v
        self.isLoaded = true
        self.lastError = (i.isEmpty && v.isEmpty) ? "No models (are you logged in?)" : nil
    }

    private static func fetch(path: String, kindFlag: String, kind: HiggsfieldModel.Kind) async -> [HiggsfieldModel] {
        let proc = CLIProcess(executable: path,
                              arguments: ["model", "list", kindFlag, "--json"], timeout: 30)
        guard let out = try? await proc.runCapturing(),
              let data = out.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { entry in
            guard let id = entry["id"] as? String ?? entry["name"] as? String else { return nil }
            let name = entry["display_name"] as? String ?? entry["title"] as? String ?? id
            return HiggsfieldModel(id: id, displayName: name, kind: kind)
        }
    }
}
```

Note: the exact JSON keys from `higgsfield model list --json` should be verified against real output during implementation (`higgsfield model list --image --json`); adjust `id`/`display_name` key names if they differ. The parser already falls back across `id`/`name` and `display_name`/`title`.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Generation/Higgsfield/HiggsfieldCatalog.swift
git commit -m "feat: add HiggsfieldCatalog from `higgsfield model list`"
```

---

### Task 13: ModelsPane provider picker + Higgsfield auth status

**Files:**
- Modify: `Sources/PalmierPro/Settings/ModelsPane.swift`

- [ ] **Step 1: Inspect ModelsPane to find the insertion point**

Run: `sed -n '1,80p' Sources/PalmierPro/Settings/ModelsPane.swift`
Identify the top-level `VStack` in `body`.

- [ ] **Step 2: Add provider picker + status state**

Add state:

```swift
    @State private var provider: GenerationProvider = GenerationProvider.selected
    @State private var higgsfieldLoggedIn: Bool = false
    @State private var checkingLogin = false
```

Add a section view:

```swift
    private var providerSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Generation Provider")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Picker("", selection: $provider) {
                ForEach(GenerationProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: provider) { _, newValue in
                GenerationProvider.selected = newValue
                if newValue == .higgsfield { Task { await refreshHiggsfield() } }
            }

            if provider == .higgsfield { higgsfieldStatusRow }
        }
    }

    private var higgsfieldStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            if HiggsfieldCLI.isAvailable && !higgsfieldLoggedIn {
                Button("Log in") { Task { try? await HiggsfieldCLI.login(); await refreshHiggsfield() } }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(AppTheme.Opacity.muted)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
    }

    private var statusColor: Color {
        if !HiggsfieldCLI.isAvailable { return AppTheme.Text.mutedColor }
        return higgsfieldLoggedIn ? .green : .orange
    }
    private var statusText: String {
        if !HiggsfieldCLI.isAvailable { return "higgsfield not found on PATH" }
        return higgsfieldLoggedIn ? "Logged in to Higgsfield" : "Not logged in"
    }

    private func refreshHiggsfield() async {
        checkingLogin = true
        higgsfieldLoggedIn = await HiggsfieldCLI.isLoggedIn()
        if higgsfieldLoggedIn { await HiggsfieldCatalog.shared.refresh() }
        checkingLogin = false
    }
```

Insert `providerSection` at the top of the `body` VStack, with a `Divider().overlay(AppTheme.Border.subtleColor)` after it, and add `.task { if provider == .higgsfield { await refreshHiggsfield() } }`.

- [ ] **Step 3: Build and visually verify**

Run: `swift build` then `swift run`.
Settings → Models. Expected: a "Generation Provider" picker; selecting Higgsfield shows login status and (if logged out) a "Log in" button.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Settings/ModelsPane.swift
git commit -m "feat: add generation provider picker and Higgsfield auth status"
```

---

## Final verification

- [ ] **Run the full test suite**

Run: `swift test`
Expected: all suites pass, including the 5 new ones (`CLILocator`, `ClaudeStreamJSONParser`, `ChatBackend`, `HiggsfieldCommand`, `HiggsfieldResult`).

- [ ] **End-to-end manual checks**

1. **Claude CLI chat (standalone):** sign out, remove API key, set backend = Claude Code CLI. Send "add a 3s black title and a fade-in." Confirm streamed reply + timeline mutates via MCP. Send a follow-up referencing the prior turn; confirm continuity (uses `--resume`). Confirm `claude mcp list` in a terminal now shows `palmier-pro`.
2. **Higgsfield generation (standalone):** sign out, provider = Higgsfield, `higgsfield auth login`. Generate an image and a video; confirm both download into the project media.
3. **Regression:** switch backend back to Palmier/API key and provider back to Palmier; confirm the existing paid paths still work unchanged.

- [ ] **Update AGENTS.md** with one line each under Architecture noting the CLI backends (chat: `ChatBackend`/`ClaudeCLIRunner`; generation: `GenerationProvider`/Higgsfield), then commit.

---

## Notes for the implementer

- The CLI chat path deliberately bypasses `runLoop()`/`ToolExecutor`: the CLI executes MCP tools itself against the live editor. Do not feed CLI `tool_use` blocks back through `ToolExecutor`.
- Image-mention inlining for the CLI path is text-only in v1 (see spec open notes).
- Verify real JSON key names from `higgsfield generate create … --json` and `higgsfield model list --json` while implementing Tasks 10/12 and adjust the defensive parsers if needed.
- All new UI must use `AppTheme` tokens; no hardcoded numbers (per AGENTS.md).
