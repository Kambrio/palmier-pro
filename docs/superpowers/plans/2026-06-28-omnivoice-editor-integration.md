# OmniVoice Editor Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the local OmniVoice runtime (Plan 1) as a selectable, no-sign-in TTS path in Palmier — wired into `generate_audio`, the model catalog, and Settings → Models — supporting plain multilingual TTS, voice design, and voice cloning.

**Architecture:** Add `GenerationProvider.omnivoice`. Register a local `AudioModelConfig` so the catalog/tool work offline. When OmniVoice is the selected provider (or the OmniVoice model is requested), `generate_audio` skips the Palmier account gate, maps its args (`prompt`/`language`/`styleInstructions`/`voice`) into an `OmniVoiceJob`, and `GenerationService.runJob` branches to a local `runOmniVoiceJob` — mirroring the existing `runHiggsfieldJob` branch — that runs the worker (Plan 1) and finalizes the produced WAV through the existing import path.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing; depends on Plan 1 (`OmniVoiceJob`, `OmniVoiceRuntime`, `OmniVoiceGenerationProvider`).

**Prerequisite:** Plan 1 (`2026-06-28-omnivoice-runtime-and-worker.md`) is merged.

---

## File Structure

- `Sources/PalmierPro/Models/MediaManifest.swift` — add `language` to `GenerationInput` (modify).
- `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceCatalog.swift` — the local `AudioModelConfig` + a `CatalogEntry` convenience init (create).
- `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceJobBuilder.swift` — pure `GenerationInput → OmniVoiceJob` mapping (create).
- `Sources/PalmierPro/Generation/Catalog/ModelCatalog.swift` — merge the local OmniVoice model so it exists offline (modify).
- `Sources/PalmierPro/Generation/Higgsfield/GenerationProvider.swift` — add `.omnivoice` (modify).
- `Sources/PalmierPro/Generation/GenerationService.swift` — `runJob` branch + `runOmniVoiceJob` + `finalizeLocalFile` (modify).
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Generate.swift` — `generateAudio` routing + voice-reference resolution (modify).
- `Sources/PalmierPro/Settings/ModelsPane.swift` — provider option + runtime panel (modify).

Tests:
- `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceCatalogTests.swift`
- `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceJobBuilderTests.swift`
- `Tests/PalmierProTests/Media/GenerationInputCodableTests.swift` (or extend an existing GenerationInput test)

---

## Task 1: Add `language` to GenerationInput

OmniVoice needs a target language; the cloud audio params don't carry one. Add an audio-only optional field (default nil keeps Codable + existing call sites unchanged).

**Files:**
- Modify: `Sources/PalmierPro/Models/MediaManifest.swift`
- Test: `Tests/PalmierProTests/Media/GenerationInputCodableTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Media/GenerationInputCodableTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("GenerationInput language")
struct GenerationInputCodableTests {

    @Test func languageRoundTrips() throws {
        var input = GenerationInput(prompt: "hi", model: "m", duration: 0, aspectRatio: "")
        input.language = "Spanish"
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(GenerationInput.self, from: data)
        #expect(decoded.language == "Spanish")
    }

    @Test func languageDefaultsNil() {
        let input = GenerationInput(prompt: "hi", model: "m", duration: 0, aspectRatio: "")
        #expect(input.language == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GenerationInputCodableTests`
Expected: FAIL — `value of type 'GenerationInput' has no member 'language'`.

- [ ] **Step 3: Add the field**

In `Sources/PalmierPro/Models/MediaManifest.swift`, inside `struct GenerationInput`, in the `// Audio-only` group (right after `var instrumental: Bool?`), add:

```swift
    /// Audio-only — OmniVoice target language (e.g. "English", "Spanish").
    var language: String?
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GenerationInputCodableTests`
Expected: PASS (2 tests). `swift build` still compiles (the synthesized memberwise init gains a defaulted trailing arg; existing call sites are unaffected because they use leading labels).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Models/MediaManifest.swift Tests/PalmierProTests/Media/GenerationInputCodableTests.swift
git commit -m "feat(omnivoice): add audio-only language to GenerationInput"
```

---

## Task 2: Local OmniVoice catalog entry

A static `AudioModelConfig` for OmniVoice, built via a `CatalogEntry` convenience init (the type otherwise only has a decoder init).

**Files:**
- Create: `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceCatalog.swift`
- Test: `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceCatalogTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceCatalogTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceCatalog")
struct OmniVoiceCatalogTests {

    @Test func modelHasExpectedShape() {
        let m = OmniVoiceCatalog.model
        #expect(m.id == OmniVoiceCatalog.modelId)
        #expect(m.category == .tts)
        #expect(m.supportsStyleInstructions)            // voice design
        #expect(m.inputs == [.text])
        #expect(m.minPromptLength >= 1)
    }

    @Test func modelIdIsStable() {
        #expect(OmniVoiceCatalog.modelId == "omnivoice-local")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OmniVoiceCatalogTests`
Expected: FAIL — `cannot find 'OmniVoiceCatalog' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Generation/OmniVoice/OmniVoiceCatalog.swift
import Foundation

/// The single local TTS model surfaced for the OmniVoice provider.
enum OmniVoiceCatalog {
    static let modelId = "omnivoice-local"

    static let caps = AudioCaps(
        category: "tts",
        voices: nil,                     // voice cloning uses a reference asset, not a fixed list
        defaultVoice: nil,
        supportsLyrics: false,
        supportsInstrumental: false,
        supportsStyleInstructions: true, // voice design via `instruct`
        durations: nil,
        minPromptLength: 1,
        inputs: ["text"],
        promptLabel: "What should it say?",
        minSeconds: 1,
        maxSeconds: 900
    )

    static let entry = CatalogEntry(
        id: modelId,
        displayName: "OmniVoice (Local)",
        uiCapabilities: .audio(caps),
        audioPricing: .flat(price: 0)    // on-device, free
    )

    static let model = AudioModelConfig(entry: entry, caps: caps)
}

extension CatalogEntry {
    /// Convenience init for locally-defined (non-Convex) catalog entries.
    init(
        id: String,
        displayName: String,
        uiCapabilities: UICapabilities,
        audioPricing: AudioPricing?
    ) {
        self.id = id
        self.kind = .audio
        self.displayName = displayName
        self.allowedEndpoints = []
        self.responseShape = .audio
        self.uiCapabilities = uiCapabilities
        self.creditsPerSecond = nil
        self.audioDiscountRate = nil
        self.creditsPerImage = nil
        self.qualities = nil
        self.audioPricing = audioPricing
        self.creditsPerSecondUpscale = nil
    }
}
```

> `AudioCaps` and `AudioModelConfig` get their memberwise initializers synthesized (plain structs, no custom init) and are in-module. `CatalogEntry`'s stored properties are all `let` but settable from within an `init` in the same module.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OmniVoiceCatalogTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Generation/OmniVoice/OmniVoiceCatalog.swift Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceCatalogTests.swift
git commit -m "feat(omnivoice): local TTS catalog entry"
```

---

## Task 3: Register the local model in ModelCatalog

Make the OmniVoice model present even with no Convex/sign-in, and keep it when Convex models load.

**Files:**
- Modify: `Sources/PalmierPro/Generation/Catalog/ModelCatalog.swift`
- Test: `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceCatalogTests.swift` (extend)

- [ ] **Step 1: Write the failing test (append to OmniVoiceCatalogTests)**

```swift
    @MainActor
    @Test func catalogIncludesOmniVoiceOffline() {
        // No Convex configured in tests → audio comes only from local registration.
        let audio = ModelCatalog.shared.audio
        #expect(audio.contains { $0.id == OmniVoiceCatalog.modelId })
        if case .audio(let m)? = ModelCatalog.shared.byId[OmniVoiceCatalog.modelId] {
            #expect(m.id == OmniVoiceCatalog.modelId)
        } else {
            Issue.record("OmniVoice model not in byId")
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OmniVoiceCatalogTests`
Expected: FAIL — OmniVoice model absent from `ModelCatalog.shared.audio`.

- [ ] **Step 3: Implement the merge**

In `Sources/PalmierPro/Generation/Catalog/ModelCatalog.swift`:

a) Add a static list of local models after the `static let shared` line:

```swift
    static let shared = ModelCatalog()

    /// Models defined locally (no Convex), e.g. the on-device OmniVoice TTS provider.
    static let localAudio: [AudioModelConfig] = [OmniVoiceCatalog.model]
```

b) Seed them in `init()` so they exist before/without a Convex load:

```swift
    private init() {
        for m in Self.localAudio {
            audio.append(m)
            byId[m.id] = .audio(m)
        }
    }
```

c) Keep them when Convex entries arrive — at the end of `apply(_:)`, just before `self.video = newVideo`, append the locals to the freshly-built audio list:

```swift
        for m in Self.localAudio {
            newAudio.append(m)
            newById[m.id] = .audio(m)
        }

        self.video = newVideo
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OmniVoiceCatalogTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Generation/Catalog/ModelCatalog.swift Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceCatalogTests.swift
git commit -m "feat(omnivoice): register local TTS model in the catalog"
```

---

## Task 4: GenerationInput → OmniVoiceJob builder

Pure mapping so routing logic stays thin and testable.

**Files:**
- Create: `Sources/PalmierPro/Generation/OmniVoice/OmniVoiceJobBuilder.swift`
- Test: `Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceJobBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceJobBuilderTests.swift
import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceJobBuilder")
struct OmniVoiceJobBuilderTests {

    private func input(_ mutate: (inout GenerationInput) -> Void) -> GenerationInput {
        var i = GenerationInput(prompt: "Hello world", model: OmniVoiceCatalog.modelId, duration: 0, aspectRatio: "")
        mutate(&i)
        return i
    }

    @Test func plainTTSDefaultsLanguageAndOmitsRef() {
        let job = OmniVoiceJobBuilder.build(genInput: input { _ in }, outputPath: "/tmp/o.wav")
        #expect(job.language == "English")
        #expect(job.refAudio == nil)
        #expect(job.segments.count == 1)
        #expect(job.segments[0].text == "Hello world")
        #expect(job.segments[0].output == "/tmp/o.wav")
        #expect(job.segments[0].instruct == nil)
    }

    @Test func usesLanguageWhenSet() {
        let job = OmniVoiceJobBuilder.build(genInput: input { $0.language = "Spanish" }, outputPath: "/tmp/o.wav")
        #expect(job.language == "Spanish")
    }

    @Test func voiceDesignFromStyleInstructions() {
        let job = OmniVoiceJobBuilder.build(genInput: input { $0.styleInstructions = "female, british accent" }, outputPath: "/tmp/o.wav")
        #expect(job.segments[0].instruct == "female, british accent")
    }

    @Test func voiceCloningWhenVoiceIsAnExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID()).wav")
        try Data([0,1,2]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let job = OmniVoiceJobBuilder.build(genInput: input { $0.voice = tmp.path }, outputPath: "/tmp/o.wav")
        #expect(job.refAudio == tmp.path)
    }

    @Test func ignoresVoiceThatIsNotAFilePath() {
        let job = OmniVoiceJobBuilder.build(genInput: input { $0.voice = "narrator" }, outputPath: "/tmp/o.wav")
        #expect(job.refAudio == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OmniVoiceJobBuilderTests`
Expected: FAIL — `cannot find 'OmniVoiceJobBuilder' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PalmierPro/Generation/OmniVoice/OmniVoiceJobBuilder.swift
import Foundation

/// Maps a generation request onto a single-segment OmniVoice worker job.
/// `voice` is treated as a reference-audio file path for cloning when it points
/// at an existing file; otherwise cloning is skipped (plain TTS / voice design).
enum OmniVoiceJobBuilder {
    static func build(genInput: GenerationInput, outputPath: String) -> OmniVoiceJob {
        let language = genInput.language?.isEmpty == false ? genInput.language! : "English"
        let instruct = genInput.styleInstructions?.isEmpty == false ? genInput.styleInstructions : nil
        let refAudio: String? = {
            guard let v = genInput.voice, FileManager.default.fileExists(atPath: v) else { return nil }
            return v
        }()
        let segment = OmniVoiceSegment(text: genInput.prompt, output: outputPath, instruct: instruct)
        return OmniVoiceJob(refAudio: refAudio, language: language, segments: [segment])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OmniVoiceJobBuilderTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Generation/OmniVoice/OmniVoiceJobBuilder.swift Tests/PalmierProTests/Generation/OmniVoice/OmniVoiceJobBuilderTests.swift
git commit -m "feat(omnivoice): GenerationInput -> worker job builder"
```

---

## Task 5: Add the `.omnivoice` provider case

**Files:**
- Modify: `Sources/PalmierPro/Generation/Higgsfield/GenerationProvider.swift`

- [ ] **Step 1: Add the case + behavior**

Edit `GenerationProvider` so it reads:

```swift
enum GenerationProvider: String, CaseIterable, Sendable {
    case palmier
    case higgsfield
    case omnivoice

    var displayName: String {
        switch self {
        case .palmier: "Palmier"
        case .higgsfield: "Higgsfield (CLI)"
        case .omnivoice: "OmniVoice (Local)"
        }
    }
```

In `canGenerate`, add the omnivoice arm (it needs neither account nor CLI — just a resolvable/provisionable runtime; we allow generation to start and let it provision on demand):

```swift
    @MainActor static var canGenerate: Bool {
        switch selected {
        case .palmier: return AccountService.shared.isSignedIn && AccountService.shared.hasCredits
        case .higgsfield: return HiggsfieldCLI.isAvailable
        case .omnivoice:
            OmniVoiceRuntime.shared.refresh()
            // Ready, or provisionable (bundled uv present) — provisioning happens on first run.
            if case .ready = OmniVoiceRuntime.shared.state { return true }
            return OmniVoiceRuntime.bundledUV() != nil
        }
    }
```

In `cannotGenerateReason`, add:

```swift
        case .omnivoice:
            return "The OmniVoice runtime isn't ready. Tell the user to open Settings → Models and install the OmniVoice (Local) runtime."
```

- [ ] **Step 2: Build to verify exhaustiveness**

Run: `swift build`
Expected: builds (all `switch`es over `GenerationProvider` are updated; the compiler flags any missed one — fix by adding an `.omnivoice` arm).

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Generation/Higgsfield/GenerationProvider.swift
git commit -m "feat(omnivoice): add local voice generation provider case"
```

---

## Task 6: GenerationService — local OmniVoice job path

Branch `runJob` to a local worker run, and finalize the produced WAV without a network download.

**Files:**
- Modify: `Sources/PalmierPro/Generation/GenerationService.swift`

- [ ] **Step 1: Branch in `runJob`**

In `runJob(...)`, the method currently starts with the higgsfield branch (line ~306). Add the omnivoice branch immediately before it:

```swift
        if GenerationProvider.selected == .omnivoice || genInput.model == OmniVoiceCatalog.modelId {
            await runOmniVoiceJob(
                placeholders: placeholders, genInput: genInput,
                editor: editor, onComplete: onComplete, onFailure: onFailure)
            return
        }

        if GenerationProvider.selected == .higgsfield {
```

- [ ] **Step 2: Add `runOmniVoiceJob` + `finalizeLocalFile`**

Add these methods to `GenerationService` (next to `runHiggsfieldJob`):

```swift
    /// Runs OmniVoice locally (Plan 1 worker) and finalizes the produced WAV.
    private func runOmniVoiceJob(
        placeholders: [MediaAsset],
        genInput: GenerationInput,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let placeholder = placeholders.first else { onFailure?(); return }
        do {
            placeholder.generationStatus = .generating
            let python = try await OmniVoiceRuntime.shared.ensureReady()
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("omnivoice-\(UUID().uuidString).wav")
            let job = OmniVoiceJobBuilder.build(genInput: genInput, outputPath: out.path)

            let produced = try await OmniVoiceGenerationProvider.generate(job: job, python: python)
            guard let firstPath = produced.first else {
                throw OmniVoiceError.generationFailed("No audio produced.")
            }
            if await finalizeLocalFile(asset: placeholder, localURL: URL(fileURLWithPath: firstPath), editor: editor) {
                onComplete?(placeholder)
                AppNotifications.generationComplete(
                    assetId: placeholder.id, projectURL: editor.projectURL,
                    assetName: placeholder.name, assetType: placeholder.type, count: 1)
            } else {
                onFailure?()
            }
        } catch {
            let message = error.localizedDescription
            Log.generation.error("omnivoice generate failed: \(message)")
            placeholder.generationStatus = .failed(message)
            onFailure?()
        }
    }

    /// Like `downloadAndFinalize` but the source is already a local file (no network).
    @discardableResult
    private func finalizeLocalFile(asset: MediaAsset, localURL: URL, editor: EditorViewModel) async -> Bool {
        asset.generationStatus = .downloading
        do {
            let destinationURL = asset.url
            try await Task.detached(priority: .utility) {
                _ = try FileIO.moveReplacingDestination(from: localURL, to: destinationURL)
            }.value
            asset.pendingDownloadURL = nil
            asset.generationStatus = .none
            editor.importMediaAsset(asset, skipAppend: true)
            editor.appendGenerationLog(for: asset)
            await editor.finalizeImportedAsset(asset)
            return true
        } catch {
            Log.generation.error("omnivoice finalize failed: \(error.localizedDescription)")
            asset.generationStatus = .failed(error.localizedDescription)
            return false
        }
    }
```

> The placeholder is created with `fileExtension: "mp3"` by `AudioGenerationSubmission`. The worker writes WAV; `downloadAndFinalize` rewrites the extension from the remote URL, but the local path has no such step — so we set the submission's `fileExtension` to `"wav"` for OmniVoice in Task 7, and `asset.url` already carries `.wav`. (If a `.mp3`-named asset ever holds WAV bytes, importers key on content, not extension, but we keep them consistent.)

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Generation/GenerationService.swift
git commit -m "feat(omnivoice): local job path in GenerationService"
```

---

## Task 7: Route generate_audio through OmniVoice

Bypass the Palmier account gate for the OmniVoice path, default to the local model, resolve a voice-reference asset to a file path, and submit with `fileExtension: "wav"`.

**Files:**
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor+Generate.swift`
- Modify: `Sources/PalmierPro/Generation/Submission/AudioGenerationSubmission.swift`

- [ ] **Step 1: Make the submission file-extension provider-aware**

In `AudioGenerationSubmission.submit(...)`, replace the hardcoded `fileExtension: "mp3"` with a computed value:

```swift
            fileExtension: GenerationProvider.selected == .omnivoice ? "wav" : "mp3",
```

- [ ] **Step 2: Branch at the top of `generateAudio`**

In `ToolExecutor+Generate.swift`, replace the opening account guards of `generateAudio` (the two `guard AccountService...` blocks, lines ~243-248) with provider-aware gating:

```swift
    func generateAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let useOmniVoice = GenerationProvider.selected == .omnivoice
            || (args.string("model") ?? "") == OmniVoiceCatalog.modelId

        if !useOmniVoice {
            guard AccountService.shared.isSignedIn else {
                throw ToolError("Generation requires signing in to Palmier. Tell the user to sign in.")
            }
            guard AccountService.shared.hasCredits else {
                throw ToolError("Out of credits. Tell the user to add credits or subscribe to keep generating.")
            }
        }

        let defaultModelId = useOmniVoice ? OmniVoiceCatalog.modelId : AudioModelConfig.allModels.first?.id
        guard let modelId = args.string("model") ?? defaultModelId else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let model = AudioModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(AudioModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }
```

(Keep the rest of the method unchanged below this point.)

- [ ] **Step 3: Resolve the voice reference + language for OmniVoice**

Still in `generateAudio`, the existing block builds `params` then `genInput` (lines ~300-323). For OmniVoice, the `voice` arg may name a project audio asset to clone; resolve it to a local file path, and carry `language` into `genInput`. Insert this just **before** the `let genInput = GenerationInput(...)` construction:

```swift
        // OmniVoice: resolve a voice-reference asset (for cloning) to a local file path.
        var omniVoiceRefPath: String?
        var omniVoiceLanguage: String?
        if useOmniVoice {
            omniVoiceLanguage = args.string("language") ?? "English"
            if let voiceRef = args.string("voice"),
               let voiceAsset = try? asset(voiceRef, editor: editor, label: "Voice reference"),
               voiceAsset.type == .audio,
               let url = editor.mediaResolver.resolveURL(for: voiceAsset.id) {
                omniVoiceRefPath = url.path
            }
        }
```

Then change the `genInput` construction's `voice:` and add `language` so the builder sees them. Replace:

```swift
        let genInput = GenerationInput(
            prompt: prompt,
            model: model.id,
            duration: durationSeconds ?? 0,
            aspectRatio: "",
            resolution: nil,
            voice: params.voice,
            lyrics: params.lyrics,
            styleInstructions: params.styleInstructions,
            instrumental: model.supportsInstrumental ? instrumental : nil
        )
```

with:

```swift
        var genInput = GenerationInput(
            prompt: prompt,
            model: model.id,
            duration: durationSeconds ?? 0,
            aspectRatio: "",
            resolution: nil,
            voice: omniVoiceRefPath ?? params.voice,
            lyrics: params.lyrics,
            styleInstructions: params.styleInstructions,
            instrumental: model.supportsInstrumental ? instrumental : nil
        )
        genInput.language = omniVoiceLanguage
```

> Why this works end-to-end: `AudioGenerationSubmission.submit` → `GenerationService.generate` creates the placeholder and (with empty `references`) makes no Convex upload, then `runJob` sees `genInput.model == OmniVoiceCatalog.modelId` (or provider `.omnivoice`) and routes to `runOmniVoiceJob`, which builds the worker job from `genInput.prompt` / `.language` / `.styleInstructions` / `.voice` (Task 4) and finalizes the WAV (Task 6).

> Discoverability (recommended, not required for function): in `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`, add an optional string `language` property to the `generate_audio` input schema (matching the style of the existing `voice`/`styleInstructions` properties), described as "OmniVoice target language, e.g. English, Spanish (TTS only)." Note in its description that for the OmniVoice provider, `voice` accepts a mediaRef of an audio asset to clone, and `styleInstructions` drives voice design. The agent can still pass these without the schema change (it just won't be self-documented).

- [ ] **Step 4: Build + manual tool check**

Run: `swift build`
Expected: builds.

Manual (with Plan 1 dev runtime present), from a `claude`/MCP session against the running app:
- Set provider to OmniVoice (Settings → Models, Task 8) or pass `model: "omnivoice-local"`.
- Call `generate_audio` with `{ "prompt": "Hello from Palmier.", "language": "English" }`.
Expected: a new audio asset appears in the library (no sign-in required); playing it speaks the line at 24 kHz.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Agent/Tools/ToolExecutor+Generate.swift Sources/PalmierPro/Generation/Submission/AudioGenerationSubmission.swift
git commit -m "feat(omnivoice): route generate_audio through the local provider"
```

---

## Task 8: Settings → Models UI

Add OmniVoice as a third provider with a runtime status/provision panel.

**Files:**
- Modify: `Sources/PalmierPro/Settings/ModelsPane.swift`

- [ ] **Step 1: Add the OmniVoice content branch**

The provider picker already iterates `GenerationProvider.allCases`, so `.omnivoice` appears automatically. Update the body's content switch (lines ~42-46) to handle it:

```swift
            if provider == .palmier {
                palmierContent
            } else if provider == .higgsfield {
                higgsfieldContent
            } else {
                omniVoiceContent
            }
```

- [ ] **Step 2: Add the runtime panel view**

Add this property + helpers to `ModelsPane` (uses only `AppTheme` constants, per the design system):

```swift
    private var runtime = OmniVoiceRuntime.shared

    @ViewBuilder
    private var omniVoiceContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle().fill(omniStatusColor).frame(width: 8, height: 8)
                Text(omniStatusText)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                omniActionButton
            }
            if case .provisioning(let value, let label) = runtime.state {
                ProgressView(value: value) {
                    Text(label).font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            Text("On-device text-to-speech (646 languages, voice cloning). Runs locally — no sign-in, no credits. First install downloads ~3.5 GB.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(AppTheme.Opacity.muted)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
        .task { runtime.refresh() }
    }

    @ViewBuilder
    private var omniActionButton: some View {
        switch runtime.state {
        case .ready:
            EmptyView()
        case .provisioning:
            Button("Installing…") {}.disabled(true)
                .buttonStyle(.capsule(.secondary, size: .regular)).controlSize(.small)
        default:
            Button("Install runtime") { Task { try? await runtime.provision() } }
                .buttonStyle(.capsule(.secondary, size: .regular)).controlSize(.small)
        }
    }

    private var omniStatusColor: Color {
        switch runtime.state {
        case .ready: return .green
        case .provisioning: return .orange
        case .error: return .red
        default: return AppTheme.Text.mutedColor
        }
    }

    private var omniStatusText: String {
        switch runtime.state {
        case .ready: return "OmniVoice runtime ready"
        case .provisioning: return "Installing runtime…"
        case .error(let m): return "Error: \(m)"
        case .notInstalled: return "Runtime not installed"
        case .unknown: return "Checking…"
        }
    }
```

- [ ] **Step 3: Build + visual check**

Run: `swift build`
Expected: builds.

Manual: `./scripts/dev.sh`, open Settings → Models, select **OmniVoice (Local)**. Expected: status row shows ready (if dev runtime present) or an "Install runtime" button; clicking it shows a progress bar driven by `OmniVoiceRuntime` provisioning.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Settings/ModelsPane.swift
git commit -m "feat(omnivoice): Settings provider option + runtime panel"
```

---

## Task 9: Verification

- [ ] **Step 1: Full build + test**

Run: `swift build && swift test`
Expected: build succeeds; all suites pass.

- [ ] **Step 2: End-to-end manual (with dev runtime)**

1. `./scripts/dev.sh`; Settings → Models → OmniVoice (Local) → status ready.
2. In the agent panel, ask: "Generate a voiceover saying 'Welcome to Palmier' and add it to the timeline." Expected: a WAV asset is generated locally (no sign-in) and placed; playback speaks the line.
3. Voice design: `generate_audio { prompt: "...", styleInstructions: "female, british accent" }` → audibly different voice.
4. Voice cloning: import a short reference WAV, then `generate_audio { prompt: "...", voice: "<that asset's mediaRef>" }` → output resembles the reference voice.

- [ ] **Step 3: Clean-machine provisioning + notarized-run check (release gate)**

Build a signed+notarized app (`scripts/release.sh`), install on a machine without `~/Documents/OmniVoice`, and confirm: Settings → Install runtime provisions via the bundled `uv`; quarantine is cleared (Task 8 of Plan 1); the spawned worker is not Gatekeeper-killed; generation succeeds. This is the spec's top open risk — verify here, not on the dev box.

- [ ] **Step 4: Finish the branch**

Invoke superpowers:finishing-a-development-branch.

---

## Self-Review Notes

- **Spec coverage:** TTS-only routing ✓ (Task 7 gates on the OmniVoice model/provider; music/SFX untouched). All three capabilities ✓ — plain TTS (language), voice design (styleInstructions→instruct), voice cloning (voice asset→ref_audio) via Task 4/7. No-sign-in ✓ (Task 5/7 bypass account gate). Detect-or-provision surfaced in UI ✓ (Task 8). Catalog offline ✓ (Task 3). Result reuses existing import/finalize ✓ (Task 6).
- **Type consistency:** `OmniVoiceCatalog.modelId`/`.model` (Task 2) used by Tasks 3/7; `GenerationInput.language` (Task 1) read by `OmniVoiceJobBuilder` (Task 4) and set in Task 7; `OmniVoiceJobBuilder.build(genInput:outputPath:)` (Task 4) called by `runOmniVoiceJob` (Task 6); `OmniVoiceGenerationProvider.generate(job:python:)` + `OmniVoiceRuntime.shared.ensureReady()` (Plan 1) called in Task 6; `GenerationProvider.omnivoice` (Task 5) referenced in Tasks 6/7/8.
- **Cross-plan dependency:** every Plan 1 symbol used here (`OmniVoiceJob`, `OmniVoiceSegment`, `OmniVoiceGenerationProvider`, `OmniVoiceRuntime`, `OmniVoiceError`, `OmniVoicePaths`) is defined in Plan 1; do not start Task 6 before Plan 1 is merged.
