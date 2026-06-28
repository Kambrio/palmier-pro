# OmniVoice Runtime + Worker Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Palmier a self-contained, on-device OmniVoice text-to-speech runtime that can turn text into a 24 kHz WAV on Apple Silicon, with no Palmier sign-in and no network at generation time — driven through a bundled Python worker.

**Architecture:** Pure-Swift app spawns a bundled `omnivoice_worker.py` under a uv-provisioned Python venv (CPython + PyTorch + `omnivoice==0.1.5`), passing a JSON job on stdin and parsing JSON-line progress on stdout (the `CLIProcess` pattern already used by the Higgsfield CLI provider). A `uv`-managed provisioner installs the runtime into Application Support on first use; an `OmniVoiceRuntime` state machine resolves an existing or provisioned runtime (mirroring `WhisperModelManager`). This plan stops at "text → WAV file"; editor/catalog/UI wiring is Plan 2.

**Tech Stack:** Swift 6.2, Foundation, Swift Testing; bundled static `uv` binary; Python 3.13 + PyTorch 2.8 (MPS) + `omnivoice==0.1.5`.

---

## File Structure

- `Sources/PalmierPro/Resources/OmniVoice/omnivoice_worker.py` — bundled Python worker (stdin JSON job → JSON-line progress → WAV per segment). Adapted from `good-news/good_news/vendor/omnivoice_worker.py` with **optional** `ref_audio` (so plain TTS / voice-design work without a reference).
- `Sources/PalmierPro/Resources/bin/uv` — bundled static `uv` binary (arm64). Checked in as a resource; signed in `bundle.sh`.
- `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceJob.swift` — `OmniVoiceJob` / `OmniVoiceSegment` Encodable job model + worker JSON encoding.
- `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceProgress.swift` — `OmniVoiceProgress` enum + line parser for worker stdout.
- `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceLocator.swift` — pure runtime-path resolver (override → App Support → dev path).
- `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceProvisioner.swift` — uv-driven venv + weights provisioning, step orchestration with injectable runner.
- `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceRuntime.swift` — `@MainActor @Observable` state machine tying locator + provisioner together; `ensureReady()`.
- `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceGenerationProvider.swift` — spawns the worker via `CLIProcess`, streams progress, returns WAV paths.
- `Sources/PalmierPro/Utilities/Constants.swift` — add `OmniVoice` path constants (modify).
- `Package.swift` — add `.copy("Resources/OmniVoice")` and `.copy("Resources/bin")` (modify).
- `scripts/bundle.sh` — copy + sign the bundled `uv` binary and copy the OmniVoice worker (modify).

Tests:
- `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceJobTests.swift`
- `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceProgressTests.swift`
- `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceLocatorTests.swift`
- `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceProvisionerTests.swift`

---

## Task 1: OmniVoice job model

Encodable model for the worker's single-language config (`ref_audio` optional, `language`, `segments[]`, `num_step`).

**Files:**
- Create: `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceJob.swift`
- Test: `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceJobTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceJobTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceJob")
struct OmniVoiceJobTests {

    private func encodedDict(_ job: OmniVoiceJob) throws -> [String: Any] {
        let data = try JSONEncoder().encode(job)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func plainTTSOmitsRefAudio() throws {
        let job = OmniVoiceJob(
            language: "English",
            segments: [OmniVoiceSegment(text: "Hello", output: "/tmp/0.wav")]
        )
        let dict = try encodedDict(job)
        #expect(dict["language"] as? String == "English")
        #expect(dict["num_step"] as? Int == 16)
        #expect(dict["ref_audio"] == nil)          // no voice cloning
        let segs = try #require(dict["segments"] as? [[String: Any]])
        #expect(segs.count == 1)
        #expect(segs[0]["text"] as? String == "Hello")
        #expect(segs[0]["output"] as? String == "/tmp/0.wav")
        #expect(segs[0]["instruct"] == nil)
    }

    @Test func voiceCloningIncludesRefAudio() throws {
        let job = OmniVoiceJob(
            refAudio: "/refs/sabina.wav",
            language: "Spanish",
            segments: [OmniVoiceSegment(text: "Hola", output: "/tmp/0.wav")]
        )
        let dict = try encodedDict(job)
        #expect(dict["ref_audio"] as? String == "/refs/sabina.wav")
    }

    @Test func voiceDesignIncludesInstruct() throws {
        let job = OmniVoiceJob(
            language: "English",
            segments: [OmniVoiceSegment(text: "Hi", output: "/tmp/0.wav", instruct: "female, british accent")]
        )
        let dict = try encodedDict(job)
        let segs = try #require(dict["segments"] as? [[String: Any]])
        #expect(segs[0]["instruct"] as? String == "female, british accent")
    }

    @Test func customNumStep() throws {
        let job = OmniVoiceJob(
            language: "English",
            segments: [OmniVoiceSegment(text: "Hi", output: "/tmp/0.wav")],
            numStep: 32
        )
        let dict = try encodedDict(job)
        #expect(dict["num_step"] as? Int == 32)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OmniVoiceJobTests`
Expected: FAIL — `cannot find 'OmniVoiceJob' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Generation/OmniVoice/OmniVoiceJob.swift
import Foundation

/// One utterance the worker synthesizes to `output` (an absolute WAV path).
struct OmniVoiceSegment: Encodable, Sendable {
    let text: String
    let output: String
    var instruct: String? = nil     // voice-design attributes (gender/age/accent/whisper)
    var duration: Double? = nil     // force exact output length, seconds
    var speed: Double? = nil

    enum CodingKeys: String, CodingKey { case text, output, instruct, duration, speed }
}

/// Single-language worker config. `refAudio == nil` means no voice cloning
/// (plain TTS or, with per-segment `instruct`, voice design).
struct OmniVoiceJob: Encodable, Sendable {
    var refAudio: String? = nil
    let language: String
    let segments: [OmniVoiceSegment]
    var numStep: Int = 16           // 16 ≈ 2× faster than the 32-step default
    var refText: String? = nil      // optional reference transcription; worker auto-ASRs if nil

    enum CodingKeys: String, CodingKey {
        case refAudio = "ref_audio"
        case language
        case segments
        case numStep = "num_step"
        case refText = "ref_text"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OmniVoiceJobTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Generation/OmniVoice/OmniVoiceJob.swift Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceJobTests.swift
git commit -m "feat(omnivoice): job model for the local TTS worker"
```

---

## Task 2: Worker progress parser

Parse the worker's JSON-line stdout into a typed enum.

**Files:**
- Create: `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceProgress.swift`
- Test: `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceProgressTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceProgressTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceProgress")
struct OmniVoiceProgressTests {

    @Test func parsesModelReady() throws {
        let line = #"{"status": "model_ready", "device": "mps", "num_step": 16}"#
        #expect(OmniVoiceProgress.parse(line) == .modelReady(device: "mps"))
    }

    @Test func parsesSegmentDone() throws {
        let line = #"{"segment": 2, "status": "done", "actual_duration": 3.48, "language": "English"}"#
        #expect(OmniVoiceProgress.parse(line) == .segmentDone(index: 2, durationSeconds: 3.48))
    }

    @Test func parsesSegmentCached() throws {
        let line = #"{"segment": 0, "status": "cached", "actual_duration": 1.2}"#
        #expect(OmniVoiceProgress.parse(line) == .segmentCached(index: 0, durationSeconds: 1.2))
    }

    @Test func parsesSegmentError() throws {
        let line = #"{"segment": 1, "status": "error", "error": "boom"}"#
        #expect(OmniVoiceProgress.parse(line) == .segmentError(index: 1, message: "boom"))
    }

    @Test func parsesComplete() throws {
        let line = #"{"status": "complete", "total": 5, "done": 4, "cached": 1, "errors": 0}"#
        #expect(OmniVoiceProgress.parse(line) == .complete(total: 5))
    }

    @Test func ignoresNonJSONAndUnknown() throws {
        #expect(OmniVoiceProgress.parse("loading model...") == nil)
        #expect(OmniVoiceProgress.parse("") == nil)
        #expect(OmniVoiceProgress.parse(#"{"status": "job_start", "job": 0}"#) == .other)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OmniVoiceProgressTests`
Expected: FAIL — `cannot find 'OmniVoiceProgress' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Generation/OmniVoice/OmniVoiceProgress.swift
import Foundation

/// One parsed line of the worker's stdout. `nil` = not JSON (ignore); `.other` =
/// a valid status line we don't act on (e.g. job_start).
enum OmniVoiceProgress: Equatable, Sendable {
    case modelReady(device: String)
    case segmentDone(index: Int, durationSeconds: Double)
    case segmentCached(index: Int, durationSeconds: Double)
    case segmentError(index: Int, message: String)
    case complete(total: Int)
    case other

    static func parse(_ line: String) -> OmniVoiceProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let status = obj["status"] as? String
        if let seg = obj["segment"] as? Int {
            switch status {
            case "done":
                return .segmentDone(index: seg, durationSeconds: obj["actual_duration"] as? Double ?? 0)
            case "cached":
                return .segmentCached(index: seg, durationSeconds: obj["actual_duration"] as? Double ?? 0)
            case "error":
                return .segmentError(index: seg, message: obj["error"] as? String ?? "unknown error")
            default:
                return .other
            }
        }
        switch status {
        case "model_ready": return .modelReady(device: obj["device"] as? String ?? "cpu")
        case "complete":    return .complete(total: obj["total"] as? Int ?? 0)
        default:            return .other
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OmniVoiceProgressTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Generation/OmniVoice/OmniVoiceProgress.swift Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceProgressTests.swift
git commit -m "feat(omnivoice): worker stdout progress parser"
```

---

## Task 3: Path constants

Add OmniVoice install/path constants alongside the existing app-path constants.

**Files:**
- Modify: `Sources/PalmierPro/Utilities/Constants.swift`

- [ ] **Step 1: Find the insertion point**

Run: `grep -n "applicationSupportDirectory\|enum Project\|Log.subsystem" Sources/PalmierPro/Utilities/Constants.swift`
Expected: shows existing constants; note the file's top-level structure (an `enum`-based namespace).

- [ ] **Step 2: Add the constants**

Append this enum to `Sources/PalmierPro/Utilities/Constants.swift` (top level, after the existing namespaces). It does not depend on any existing symbol except `Log.subsystem` (already in the module):

```swift
/// Filesystem locations for the local OmniVoice runtime.
enum OmniVoicePaths {
    /// ~/Library/Application Support/PalmierPro/OmniVoice
    static var installRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Log.subsystem)/OmniVoice", isDirectory: true)
    }

    /// The provisioned venv's python interpreter.
    static var provisionedPython: URL {
        installRoot.appendingPathComponent(".venv/bin/python3", isDirectory: false)
    }

    /// Known developer install (reused so we don't re-download on dev machines).
    static var devPython: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/OmniVoice/.venv/bin/python3", isDirectory: false)
    }

    /// HuggingFace cache kept inside the install root so weights are local + removable.
    static var hfCache: URL { installRoot.appendingPathComponent("hf-cache", isDirectory: true) }

    static let pythonPin = "3.13"
    static let omniVoiceVersion = "0.1.5"
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no error.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Utilities/Constants.swift
git commit -m "feat(omnivoice): runtime path + version constants"
```

---

## Task 4: Runtime locator

Pure, testable resolver: pick the first usable python from override → provisioned → dev path. "Usable" is an injected predicate (so tests don't run Python).

**Files:**
- Create: `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceLocator.swift`
- Test: `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceLocatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceLocatorTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceLocator")
struct OmniVoiceLocatorTests {
    private let provisioned = URL(fileURLWithPath: "/as/.venv/bin/python3")
    private let dev = URL(fileURLWithPath: "/home/dev/.venv/bin/python3")
    private let override = URL(fileURLWithPath: "/custom/python3")

    private func locator(usable: Set<String>) -> OmniVoiceLocator {
        OmniVoiceLocator(
            provisionedPython: provisioned,
            devPython: dev,
            isUsable: { usable.contains($0.path) }
        )
    }

    @Test func prefersOverrideWhenUsable() {
        let l = locator(usable: [override.path, provisioned.path, dev.path])
        #expect(l.resolve(override: override) == override)
    }

    @Test func fallsThroughUnusableOverrideToProvisioned() {
        let l = locator(usable: [provisioned.path])
        #expect(l.resolve(override: override) == provisioned)
    }

    @Test func usesDevWhenNothingElse() {
        let l = locator(usable: [dev.path])
        #expect(l.resolve(override: nil) == dev)
    }

    @Test func returnsNilWhenNoneUsable() {
        let l = locator(usable: [])
        #expect(l.resolve(override: override) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OmniVoiceLocatorTests`
Expected: FAIL — `cannot find 'OmniVoiceLocator' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Generation/OmniVoice/OmniVoiceLocator.swift
import Foundation

/// Resolves a usable OmniVoice python interpreter. Probe order:
/// explicit override → provisioned (App Support) → known dev install.
struct OmniVoiceLocator: Sendable {
    let provisionedPython: URL
    let devPython: URL
    /// Returns true if `python -c "import omnivoice"` succeeds for this interpreter.
    let isUsable: @Sendable (URL) -> Bool

    init(
        provisionedPython: URL = OmniVoicePaths.provisionedPython,
        devPython: URL = OmniVoicePaths.devPython,
        isUsable: @escaping @Sendable (URL) -> Bool = OmniVoiceLocator.probeImportOmniVoice
    ) {
        self.provisionedPython = provisionedPython
        self.devPython = devPython
        self.isUsable = isUsable
    }

    func resolve(override: URL?) -> URL? {
        let candidates = [override, provisionedPython, devPython].compactMap { $0 }
        return candidates.first(where: isUsable)
    }

    /// Default predicate: the interpreter exists and can import omnivoice. Cheap-ish
    /// (imports torch), so callers cache the result in the runtime state machine.
    static func probeImportOmniVoice(_ python: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let proc = Process()
        proc.executableURL = python
        proc.arguments = ["-c", "import omnivoice"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OmniVoiceLocatorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Generation/OmniVoice/OmniVoiceLocator.swift Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceLocatorTests.swift
git commit -m "feat(omnivoice): runtime python locator with probe order"
```

---

## Task 5: Provisioner (uv-driven)

Orchestrate the uv steps. The actual process execution is injected so the orchestration + the produced command lines are unit-tested without running uv.

**Files:**
- Create: `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceProvisioner.swift`
- Test: `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceProvisionerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceProvisionerTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceProvisioner")
struct OmniVoiceProvisionerTests {

    private func makeProvisioner(record: @escaping @Sendable (OmniVoiceProvisioner.Step) -> Void) -> OmniVoiceProvisioner {
        OmniVoiceProvisioner(
            uvPath: URL(fileURLWithPath: "/bundle/uv"),
            installRoot: URL(fileURLWithPath: "/as/OmniVoice"),
            hfCache: URL(fileURLWithPath: "/as/OmniVoice/hf-cache"),
            pythonPin: "3.13",
            omniVoiceVersion: "0.1.5",
            run: { step in record(step) }
        )
    }

    @Test func runsStepsInOrderWithExpectedArgv() async throws {
        let box = StepBox()
        let progress = ProgressBox()
        let p = makeProvisioner(record: { box.append($0) })
        let python = try await p.provision { value, _ in progress.append(value) }

        let steps = box.steps
        #expect(steps.count == 4)
        // 1. install pinned CPython
        #expect(steps[0].argv == ["python", "install", "3.13"])
        // 2. create the venv with that python
        #expect(steps[1].argv == ["venv", "--python", "3.13", "/as/OmniVoice/.venv"])
        // 3. pip install omnivoice into the venv
        #expect(steps[2].argv == ["pip", "install", "--python", "/as/OmniVoice/.venv/bin/python3", "omnivoice==0.1.5"])
        // 4. snapshot-download the model weights into the local HF cache
        #expect(steps[3].argv.prefix(3) == ["run", "--python", "/as/OmniVoice/.venv/bin/python3"])
        #expect(steps[3].env["HF_HOME"] == "/as/OmniVoice/hf-cache")

        #expect(python == URL(fileURLWithPath: "/as/OmniVoice/.venv/bin/python3"))
        #expect(progress.values.last == 1.0)         // ends at 100%
        #expect(progress.values == progress.values.sorted())   // monotonic
    }

    @Test func failingStepThrowsAndStops() async {
        let box = StepBox()
        let p = OmniVoiceProvisioner(
            uvPath: URL(fileURLWithPath: "/bundle/uv"),
            installRoot: URL(fileURLWithPath: "/as/OmniVoice"),
            hfCache: URL(fileURLWithPath: "/as/OmniVoice/hf-cache"),
            pythonPin: "3.13",
            omniVoiceVersion: "0.1.5",
            run: { step in
                box.append(step)
                if step.argv.first == "venv" { throw CLIProcessError.nonZeroExit(code: 1, stderr: "no python") }
            }
        )
        await #expect(throws: (any Error).self) {
            _ = try await p.provision { _, _ in }
        }
        #expect(box.steps.count == 2)   // stopped at the failing venv step
    }
}

private final class StepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [OmniVoiceProvisioner.Step] = []
    func append(_ s: OmniVoiceProvisioner.Step) { lock.lock(); _steps.append(s); lock.unlock() }
    var steps: [OmniVoiceProvisioner.Step] { lock.lock(); defer { lock.unlock() }; return _steps }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    func append(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OmniVoiceProvisionerTests`
Expected: FAIL — `cannot find 'OmniVoiceProvisioner' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Generation/OmniVoice/OmniVoiceProvisioner.swift
import Foundation

/// Builds a self-contained OmniVoice runtime under `installRoot` using a bundled `uv`:
/// pinned CPython → venv → `pip install omnivoice` → snapshot-download weights.
/// Process execution is injected via `run` so the orchestration is unit-testable.
struct OmniVoiceProvisioner: Sendable {
    struct Step: Sendable {
        let argv: [String]
        let env: [String: String]
    }

    let uvPath: URL
    let installRoot: URL
    let hfCache: URL
    let pythonPin: String
    let omniVoiceVersion: String
    let run: @Sendable (Step) async throws -> Void

    init(
        uvPath: URL,
        installRoot: URL = OmniVoicePaths.installRoot,
        hfCache: URL = OmniVoicePaths.hfCache,
        pythonPin: String = OmniVoicePaths.pythonPin,
        omniVoiceVersion: String = OmniVoicePaths.omniVoiceVersion,
        run: (@Sendable (Step) async throws -> Void)? = nil
    ) {
        self.uvPath = uvPath
        self.installRoot = installRoot
        self.hfCache = hfCache
        self.pythonPin = pythonPin
        self.omniVoiceVersion = omniVoiceVersion
        self.run = run ?? OmniVoiceProvisioner.runWithCLIProcess(uvPath: uvPath)
    }

    var venvPython: URL { installRoot.appendingPathComponent(".venv/bin/python3") }

    /// Runs all steps in order, reporting fractional progress + a human label.
    /// Returns the provisioned venv python on success. The caller creates
    /// `installRoot`/`hfCache` first (keeps this pure + unit-testable with fake paths).
    @discardableResult
    func provision(progress: @Sendable (Double, String) -> Void) async throws -> URL {
        let venv = installRoot.appendingPathComponent(".venv")
        let hf = hfCache.path
        let steps: [(Step, String)] = [
            (Step(argv: ["python", "install", pythonPin], env: [:]),
             "Installing Python \(pythonPin)"),
            (Step(argv: ["venv", "--python", pythonPin, venv.path], env: [:]),
             "Creating environment"),
            (Step(argv: ["pip", "install", "--python", venvPython.path, "omnivoice==\(omniVoiceVersion)"], env: [:]),
             "Installing OmniVoice (PyTorch — this is large)"),
            (Step(argv: ["run", "--python", venvPython.path, "python", "-c",
                         "from huggingface_hub import snapshot_download; snapshot_download('k2-fsa/OmniVoice')"],
                  env: ["HF_HOME": hf]),
             "Downloading model weights"),
        ]

        for (i, item) in steps.enumerated() {
            progress(Double(i) / Double(steps.count), item.1)
            try await run(item.0)
        }
        progress(1.0, "Ready")
        return venvPython
    }

    /// Default executor: each Step becomes a `uv` invocation via CLIProcess.
    static func runWithCLIProcess(uvPath: URL) -> @Sendable (Step) async throws -> Void {
        { step in
            var env = ProcessInfo.processInfo.environment
            for (k, v) in step.env { env[k] = v }
            _ = try await CLIProcess(
                executable: uvPath.path, arguments: step.argv,
                environment: env, timeout: 3600
            ).runCapturing()
        }
    }
}
```

> Note: `CLIProcess(executable:arguments:environment:timeout:)` — `environment` and `timeout` are existing members (see `Sources/PalmierPro/Utilities/CLIProcess.swift:20-31`); they're set via the memberwise/struct initializer with the other fields defaulted.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OmniVoiceProvisionerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Generation/OmniVoice/OmniVoiceProvisioner.swift Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceProvisionerTests.swift
git commit -m "feat(omnivoice): uv-driven runtime provisioner"
```

---

## Task 6: The Python worker

Bundle the adapted worker. It differs from good-news's only by making `ref_audio` optional (so plain TTS / voice design work without a reference).

**Files:**
- Create: `Sources/PalmierPro/Resources/OmniVoice/omnivoice_worker.py`

- [ ] **Step 1: Write the worker**

```python
#!/usr/bin/env python3
"""OmniVoice worker for Palmier. Reads one JSON job on stdin, loads the model once,
generates each segment to its `output` WAV, and streams JSON-line progress on stdout.

Config:
{
  "ref_audio": "/path/ref.wav",   # optional — omit for plain TTS / voice design
  "ref_text": "...",              # optional reference transcription (else auto-ASR)
  "language": "English",
  "num_step": 16,
  "segments": [
    {"text": "Hello", "output": "/tmp/0.wav", "instruct": "female, british accent"}
  ]
}

Output lines:
{"status": "model_ready", "device": "mps", "num_step": 16}
{"status": "job_start", "language": "English", "count": 1}
{"segment": 0, "status": "done", "actual_duration": 3.48, "language": "English"}
{"segment": 0, "status": "cached", "actual_duration": 3.48}
{"segment": 0, "status": "error", "error": "..."}
{"status": "complete", "total": 1, "done": 1, "cached": 0, "errors": 0}
"""

import json
import sys
import time
from pathlib import Path

import torch
import torchaudio

from omnivoice import OmniVoice, OmniVoiceGenerationConfig

SAMPLE_RATE = 24000


def get_device():
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def emit(obj):
    print(json.dumps(obj), flush=True)


def main():
    config = json.loads(sys.stdin.read())
    language = config.get("language", "English")
    segments = config.get("segments", [])
    ref_audio = config.get("ref_audio")  # may be None

    if not segments:
        emit({"status": "complete", "total": 0, "done": 0, "cached": 0, "errors": 0})
        return

    device = get_device()
    model = OmniVoice.from_pretrained("k2-fsa/OmniVoice", device_map=device)

    prompt = None
    if ref_audio:
        if not config.get("ref_text"):
            model.load_asr_model()
        prompt = model.create_voice_clone_prompt(
            ref_audio=ref_audio,
            ref_text=config.get("ref_text"),
            preprocess_prompt=True,
        )

    num_step = int(config.get("num_step", 16))
    gen_config = OmniVoiceGenerationConfig(num_step=num_step)
    emit({"status": "model_ready", "device": device, "num_step": num_step})
    emit({"status": "job_start", "language": language, "count": len(segments)})

    done = cached = errors = 0
    for i, seg in enumerate(segments):
        out_path = seg["output"]
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        if Path(out_path).exists() and Path(out_path).stat().st_size > 0:
            try:
                info = torchaudio.info(out_path)
                emit({"segment": i, "status": "cached",
                      "actual_duration": round(info.num_frames / info.sample_rate, 2)})
                cached += 1
                continue
            except Exception:
                pass

        kwargs = {"text": seg["text"], "language": language, "generation_config": gen_config}
        if prompt is not None:
            kwargs["voice_clone_prompt"] = prompt
        if seg.get("instruct"):
            kwargs["instruct"] = seg["instruct"]
        if seg.get("duration"):
            kwargs["duration"] = seg["duration"]
        if seg.get("speed"):
            kwargs["speed"] = seg["speed"]

        try:
            t0 = time.time()
            audios = model.generate(**kwargs)
            audio = audios[0]
            torchaudio.save(out_path, audio.cpu(), SAMPLE_RATE)
            emit({"segment": i, "status": "done",
                  "actual_duration": round(audio.shape[-1] / SAMPLE_RATE, 2),
                  "gen_time": round(time.time() - t0, 1), "language": language})
            done += 1
        except Exception as e:
            emit({"segment": i, "status": "error", "error": str(e)[:300]})
            errors += 1

    emit({"status": "complete", "total": done + cached,
          "done": done, "cached": cached, "errors": errors})


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Manually verify the worker against the dev runtime (opt-in)**

Run (uses your existing dev install; adjust path if needed):
```bash
echo '{"language":"English","num_step":16,"segments":[{"text":"Hello from Palmier.","output":"/tmp/ov_test.wav"}]}' \
  | ~/Documents/OmniVoice/.venv/bin/python3 Sources/PalmierPro/Resources/OmniVoice/omnivoice_worker.py
```
Expected: JSON lines ending in `{"status": "complete", ...}` and a non-empty `/tmp/ov_test.wav`. Verify: `afinfo /tmp/ov_test.wav` reports 24000 Hz.

> If `omnivoice==0.1.5` changed `generate` / `create_voice_clone_prompt` signatures vs the 0.1.2 dev venv, reconcile here (spec open-risk #4). The worker only relies on `from_pretrained`, `load_asr_model`, `create_voice_clone_prompt(ref_audio:, ref_text:, preprocess_prompt:)`, and `generate(text:, language:, voice_clone_prompt:, instruct:, duration:, speed:, generation_config:)`.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Resources/OmniVoice/omnivoice_worker.py
git commit -m "feat(omnivoice): bundled python worker (optional ref_audio)"
```

---

## Task 7: Bundle the worker + uv resources (Package.swift + bundle.sh)

Make the worker and a static `uv` binary ship inside the app and get found at runtime.

**Files:**
- Add binary: `Sources/PalmierPro/Resources/bin/uv`
- Modify: `Package.swift`
- Modify: `scripts/bundle.sh`

- [ ] **Step 1: Add the uv binary**

Run:
```bash
mkdir -p Sources/PalmierPro/Resources/bin
curl -fsSL https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz \
  | tar -xz -C /tmp
cp /tmp/uv-aarch64-apple-darwin/uv Sources/PalmierPro/Resources/bin/uv
chmod +x Sources/PalmierPro/Resources/bin/uv
Sources/PalmierPro/Resources/bin/uv --version
```
Expected: prints a `uv x.y.z` version line.

- [ ] **Step 2: Declare the resources in Package.swift**

In `Package.swift`, the target's `resources:` array currently ends at `.copy("Resources/Models"),` (around line 51). Add two entries:

```swift
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/MCPB/palmier-pro.mcpb"),
                .copy("Resources/Images"),
                .copy("Resources/Changelog"),
                .copy("Resources/Skills"),
                .copy("Resources/Models"),
                .copy("Resources/OmniVoice"),
                .copy("Resources/bin"),
```

- [ ] **Step 3: Build to verify resources resolve**

Run: `swift build`
Expected: builds; `swift run` would expose `Bundle.module.url(forResource: "uv", withExtension: nil, subdirectory: "bin")`.

- [ ] **Step 4: Copy + sign in bundle.sh**

In `scripts/bundle.sh`, after the `Models/` copy block (ends at line 117) and before the `.metallib` check (line 119), add:

```bash
if [ -d "$RES_BUNDLE/OmniVoice" ]; then
  cp -R "$RES_BUNDLE/OmniVoice" "$APP/Contents/Resources/"
else
  echo "!! missing OmniVoice/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/bin" ]; then
  cp -R "$RES_BUNDLE/bin" "$APP/Contents/Resources/"
  chmod +x "$APP/Contents/Resources/bin/uv"
else
  echo "!! missing bin/ (uv) in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
```

Then, in the Developer ID signing section, sign the `uv` binary with the hardened runtime **before** the main-app signing (insert immediately before `echo "==> Codesigning main app"` at line 188):

```bash
echo "==> Codesigning bundled uv binary"
codesign --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP/Contents/Resources/bin/uv"
```

> Why this placement: nested executables must be signed before the enclosing app, same as the Sparkle helpers above. `uv` is a CLI we spawn, not loaded into our address space, so it needs no special entitlement — only a valid hardened-runtime signature so notarization passes. The Python interpreter + torch dylibs that `uv` later provisions live in Application Support (user data, never inside the `.app`), so they are not part of notarization; the runtime clears their quarantine xattr (Task 8).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Resources/bin/uv Package.swift scripts/bundle.sh
git commit -m "build(omnivoice): bundle + sign uv binary and worker resource"
```

---

## Task 8: Runtime state machine

Tie locator + provisioner together as the app-facing `@Observable` runtime. Resolves an existing runtime cheaply; provisions on demand; strips quarantine after provisioning.

**Files:**
- Create: `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceRuntime.swift`

- [ ] **Step 1: Write the implementation**

```swift
// Sources/PalmierPro/Generation/OmniVoice/OmniVoiceRuntime.swift
import Foundation
import Observation

@MainActor
@Observable
final class OmniVoiceRuntime {
    static let shared = OmniVoiceRuntime()

    enum State: Equatable {
        case unknown
        case notInstalled
        case provisioning(Double, String)
        case ready(URL)            // resolved python interpreter
        case error(String)
    }

    private(set) var state: State = .unknown

    /// User-set interpreter path override (Settings). Persisted in UserDefaults.
    var overridePath: String? {
        get { UserDefaults.standard.string(forKey: Self.overrideKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.overrideKey) }
    }
    private static let overrideKey = "io.palmier.pro.omnivoice.pythonOverride"

    private init() {}

    var resolvedPython: URL? {
        if case .ready(let url) = state { return url }
        return nil
    }

    /// Cheap-ish disk/import probe (no network). Updates `state`.
    func refresh() {
        if case .provisioning = state { return }
        let override = overridePath.map { URL(fileURLWithPath: $0) }
        if let python = OmniVoiceLocator().resolve(override: override) {
            state = .ready(python)
        } else if state == .unknown {
            state = .notInstalled
        }
    }

    /// Resolve or provision. Throws if provisioning fails.
    func ensureReady() async throws -> URL {
        refresh()
        if case .ready(let url) = state { return url }
        return try await provision()
    }

    @discardableResult
    func provision() async throws -> URL {
        guard let uv = Self.bundledUV() else {
            state = .error("Bundled uv binary missing.")
            throw OmniVoiceError.runtimeUnavailable("Bundled uv binary missing.")
        }
        state = .provisioning(0, "Starting")
        try? FileManager.default.createDirectory(at: OmniVoicePaths.installRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: OmniVoicePaths.hfCache, withIntermediateDirectories: true)
        let provisioner = OmniVoiceProvisioner(uvPath: uv)
        do {
            let python = try await provisioner.provision { [weak self] value, label in
                Task { @MainActor in
                    guard let self, case .provisioning = self.state else { return }
                    self.state = .provisioning(value, label)
                }
            }
            Self.clearQuarantine(at: OmniVoicePaths.installRoot)
            state = .ready(python)
            return python
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    static func bundledUV() -> URL? {
        Bundle.module.url(forResource: "uv", withExtension: nil, subdirectory: "bin")
    }

    static func bundledWorker() -> URL? {
        Bundle.module.url(forResource: "omnivoice_worker", withExtension: "py", subdirectory: "OmniVoice")
    }

    /// Freshly-provisioned python + torch dylibs carry a quarantine xattr; clear it so
    /// Gatekeeper doesn't kill the spawned interpreter. They run as a child process,
    /// so Palmier's own hardened runtime / library-validation never gates them.
    static func clearQuarantine(at root: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-dr", "com.apple.quarantine", root.path]
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }
}

enum OmniVoiceError: LocalizedError {
    case runtimeUnavailable(String)
    case workerMissing
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let m): return m
        case .workerMissing: return "OmniVoice worker script missing from the app bundle."
        case .generationFailed(let m): return m
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds. (`Bundle.module` is available because the target declares resources.)

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Generation/OmniVoice/OmniVoiceRuntime.swift
git commit -m "feat(omnivoice): runtime state machine (resolve/provision/quarantine)"
```

---

## Task 9: Generation provider (worker bridge)

Spawn the worker via `CLIProcess`, stream progress, return the produced WAV paths. This is the public entry point Plan 2 calls.

**Files:**
- Create: `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceGenerationProvider.swift`

- [ ] **Step 1: Write the implementation**

```swift
// Sources/PalmierPro/Generation/OmniVoice/OmniVoiceGenerationProvider.swift
import Foundation

/// Runs one OmniVoice job through the bundled worker and returns the WAV path(s)
/// that completed. Structurally analogous to HiggsfieldGenerationProvider.generate.
struct OmniVoiceGenerationProvider {

    /// - Parameter onProgress: called on the main actor for each parsed progress line.
    @MainActor
    static func generate(
        job: OmniVoiceJob,
        python: URL,
        onProgress: (@MainActor (OmniVoiceProgress) -> Void)? = nil
    ) async throws -> [String] {
        guard let worker = OmniVoiceRuntime.bundledWorker() else {
            throw OmniVoiceError.workerMissing
        }

        let payload = try JSONEncoder().encode(job)
        let jsonInput = String(decoding: payload, as: UTF8.self)

        // Worker reads the whole job from stdin; CLIProcess doesn't write stdin, so we
        // pass it via a temp file the worker reads (python "-" reads stdin; we instead
        // feed the file path as argv[1] is not supported — use a stdin redirect through /bin/sh).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnivoice-job-\(UUID().uuidString).json")
        try jsonInput.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = OmniVoicePaths.hfCache.path

        // Run: /bin/sh -c '"python" "worker.py" < "job.json"' so stdin is the job file.
        let shCommand = "\(shQuote(python.path)) \(shQuote(worker.path)) < \(shQuote(tmp.path))"
        let proc = CLIProcess(
            executable: "/bin/sh",
            arguments: ["-c", shCommand],
            environment: env,
            idleTimeout: 600           // long model load + per-segment synth; watchdog on silence
        )

        var completed = false
        for try await line in proc.streamLines() {
            guard let progress = OmniVoiceProgress.parse(line) else { continue }
            onProgress?(progress)
            if case .complete = progress { completed = true }
        }

        let produced = job.segments
            .map(\.output)
            .filter { FileManager.default.fileExists(atPath: $0) }

        guard completed, !produced.isEmpty else {
            throw OmniVoiceError.generationFailed("Worker produced no audio.")
        }
        return produced
    }

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

> Why `/bin/sh -c … < file`: `CLIProcess` captures stdout/stderr but does not write to the child's stdin. Redirecting the job file into stdin via the shell keeps the worker's stdin contract unchanged and avoids extending `CLIProcess`.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Generation/OmniVoice/OmniVoiceGenerationProvider.swift
git commit -m "feat(omnivoice): worker bridge returning WAV paths"
```

---

## Task 10: End-to-end integration test (opt-in)

A single test that runs the real worker when a runtime is present, skipped otherwise (so CI stays green without the model).

**Files:**
- Create: `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceEndToEndTests.swift`

- [ ] **Step 1: Write the test**

```swift
// Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceEndToEndTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoice end-to-end (opt-in)")
struct OmniVoiceEndToEndTests {

    /// Runs only when PALMIER_OMNIVOICE_E2E=1 AND a usable runtime resolves.
    @Test func synthesizesAWav() async throws {
        guard ProcessInfo.processInfo.environment["PALMIER_OMNIVOICE_E2E"] == "1" else { return }
        guard let python = OmniVoiceLocator().resolve(override: nil) else { return }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ov-e2e-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }

        let job = OmniVoiceJob(
            language: "English",
            segments: [OmniVoiceSegment(text: "Hello from Palmier.", output: out.path)]
        )
        let produced = try await OmniVoiceGenerationProvider.generate(job: job, python: python)
        #expect(produced == [out.path])
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0
        #expect(size > 1000)
    }
}
```

- [ ] **Step 2: Run it (CI-safe + opt-in)**

Run (skips, fast): `swift test --filter OmniVoiceEndToEndTests`
Expected: PASS (test returns early — no runtime asserted).

Run (real, on your machine): `PALMIER_OMNIVOICE_E2E=1 swift test --filter OmniVoiceEndToEndTests`
Expected: PASS — produces a non-empty WAV via the dev runtime.

- [ ] **Step 3: Commit**

```bash
git add Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceEndToEndTests.swift
git commit -m "test(omnivoice): opt-in end-to-end worker synthesis"
```

---

## Task 11: Full-suite verification

- [ ] **Step 1: Build + test**

Run: `swift build && swift test`
Expected: build succeeds; all suites pass (the e2e test no-ops without the env var).

- [ ] **Step 2: Manual provisioning smoke (opt-in, network + multi-GB)**

This exercises `OmniVoiceProvisioner` against the real bundled `uv`. Only run when you want to validate a clean provision:
```bash
swift run    # then trigger provisioning from a temporary debug call, or run Plan 2's Settings button
```
Expected: `OmniVoicePaths.installRoot` gains `.venv` + `hf-cache`; `OmniVoiceLocator().resolve(override:nil)` returns the provisioned python; `state == .ready`.

- [ ] **Step 3: Confirm no regressions, then proceed to Plan 2.**

---

## Self-Review Notes

- **Spec coverage (Plan 1 portion):** uv-managed provisioner ✓ (Task 5/7), bundled `uv` signed for notarization ✓ (Task 7), detect-or-provision ✓ (Task 4/8), quarantine clear ✓ (Task 8), bundled worker with optional ref_audio for all three capabilities' plumbing ✓ (Task 6), worker bridge → WAV ✓ (Task 9). Editor/catalog/UI + voice-reference concept are Plan 2.
- **Type consistency:** `OmniVoiceJob`/`OmniVoiceSegment` (Task 1) are consumed unchanged in Tasks 9/10; `OmniVoiceProgress` cases (Task 2) match the parser and the bridge's `.complete` check; `OmniVoiceProvisioner.Step`/`provision(progress:)` (Task 5) match the runtime caller (Task 8); `OmniVoiceRuntime.bundledUV/bundledWorker/resolvedPython/ensureReady` (Task 8) match Plan 2's call sites.
- **Open risk carried forward:** OmniVoice 0.1.5 API parity is verified in Task 6 Step 2 before it can mislead later tasks.
