# Whisper Transcription Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Whisper (via WhisperKit) as an in-process transcription backend with in-app downloadable models, so Apple-unsupported languages (e.g. Russian) can be transcribed and captioned, routing automatically by language.

**Architecture:** Introduce a `TranscriptionBackend` protocol behind the existing `TranscriptionResult` value type. The current Apple logic moves into `AppleSpeechBackend`; a new `WhisperBackend` drives WhisperKit. The existing `Transcription` enum keeps its public API and becomes a router that resolves language and picks a backend via a pure decision function. WhisperKit's name-colliding types are isolated in a `WhisperKitRunner` that returns neutral structs.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, WhisperKit (CoreML), Swift Testing + XCTest. macOS 26, arm64.

**Spec:** `docs/superpowers/specs/2026-06-24-whisper-transcription-backend-design.md`

---

## File Structure

**Create:**
- `Sources/PalmierPro/Transcription/Backends/TranscriptionBackend.swift` — protocol + engine-mode + backend-choice enums.
- `Sources/PalmierPro/Transcription/Backends/AppleSpeechBackend.swift` — current Apple logic behind the protocol.
- `Sources/PalmierPro/Transcription/Backends/WhisperBackend.swift` — Whisper impl; **no `import WhisperKit`**; uses runner + mapper.
- `Sources/PalmierPro/Transcription/Whisper/WhisperModelCatalog.swift` — curated model tiers + language set.
- `Sources/PalmierPro/Transcription/Whisper/WhisperPreferences.swift` — UserDefaults: engine mode + active model id.
- `Sources/PalmierPro/Transcription/Whisper/WhisperModelManager.swift` — `@MainActor @Observable`: download/state/active/delete/storage.
- `Sources/PalmierPro/Transcription/Whisper/WhisperKitRunner.swift` — **the only file importing WhisperKit**: download, detect, transcribe → neutral `RawTranscript`.
- `Sources/PalmierPro/Transcription/Whisper/WhisperTranscriptMapper.swift` — pure `RawTranscript → TranscriptionResult`.
- `Sources/PalmierPro/Transcription/TranscriptionRouter.swift` — pure `decide(...)` decision function.
- `Sources/PalmierPro/Settings/TranscriptionPane.swift` — Settings UI.
- Tests: `Tests/PalmierProTests/Transcription/{RouterDecisionTests,WhisperModelCatalogTests,WhisperTranscriptMapperTests,TranscriptCacheKeyTests,AvailableLanguagesTests}.swift`.

**Modify:**
- `Package.swift` — add WhisperKit dependency + product.
- `Sources/PalmierPro/Transcription/Transcription.swift` — route through backends; add `availableLanguages()`.
- `Sources/PalmierPro/Transcription/TranscriptCache.swift` — key includes backend + model id.
- `Sources/PalmierPro/Settings/SettingsView.swift` — add `.transcription` tab.
- `Sources/PalmierPro/MediaPanel/CaptionsTab/CaptionTab.swift` — picker uses `availableLanguages()` + Whisper tag.
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Captions.swift` — match language against `availableLanguages()`.
- `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift` — update `add_captions` language description.

**Note on the WhisperKit type collision:** WhisperKit exports top-level `TranscriptionResult`, `TranscriptionSegment`, and `WordTiming` structs whose names collide with Palmier's `TranscriptionResult`/`TranscriptionSegment`. Only `WhisperKitRunner.swift` imports WhisperKit; it returns Palmier-owned neutral structs (`RawTranscript`/`RawSegment`/`RawWord`), so no other file ever resolves an ambiguous name.

---

## Task 1: Add WhisperKit dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the package dependency**

In `Package.swift`, add to the `dependencies` array (after the lottie-ios line):

```swift
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
```

- [ ] **Step 2: Add the product to the target**

In the `PalmierPro` target's `dependencies` array (after the `Lottie` product):

```swift
                .product(name: "WhisperKit", package: "WhisperKit"),
```

- [ ] **Step 3: Resolve and build**

Run: `swift package resolve && swift build`
Expected: WhisperKit resolves and the project builds (existing code unchanged). If `swift build` reports a newer minimum WhisperKit version, bump the `from:` to the version it names and re-run.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add WhisperKit dependency"
```

---

## Task 2: Backend protocol + engine-mode + choice enums

**Files:**
- Create: `Sources/PalmierPro/Transcription/Backends/TranscriptionBackend.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// How transcription chooses between the Apple and Whisper backends.
enum TranscriptionEngineMode: String, CaseIterable, Sendable {
    case automatic      // Apple for supported languages, Whisper otherwise
    case alwaysApple
    case alwaysWhisper

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .alwaysApple: "Always Apple"
        case .alwaysWhisper: "Always Whisper"
        }
    }
}

/// Which concrete backend the router resolved to.
enum TranscriptionBackendChoice: Sendable { case apple, whisper }

/// A pluggable speech-to-text engine. Both backends produce the same value type
/// so every consumer (TranscriptCache, captions, get_transcript, search) is unchanged.
protocol TranscriptionBackend: Sendable {
    /// Transcribe a decoded audio file (16 kHz mono PCM .caf produced by the router).
    /// `language` is a BCP-47 *language* (region optional); nil means auto.
    func transcribe(fileURL: URL, language: Locale?, censorProfanity: Bool) async throws -> TranscriptionResult

    /// BCP-47 language codes (e.g. "en", "ru") this backend can handle.
    func supportedLanguages() async -> Set<String>
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds (nothing references it yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Transcription/Backends/TranscriptionBackend.swift
git commit -m "feat: add TranscriptionBackend protocol and engine-mode enums"
```

---

## Task 3: Router decision function (pure, TDD)

**Files:**
- Create: `Sources/PalmierPro/Transcription/TranscriptionRouter.swift`
- Test: `Tests/PalmierProTests/Transcription/RouterDecisionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import PalmierPro

struct RouterDecisionTests {
    @Test func alwaysAppleAlwaysPicksApple() throws {
        #expect(try TranscriptionRouter.decide(mode: .alwaysApple, appleSupportsLanguage: false, whisperModelAvailable: true) == .apple)
        #expect(try TranscriptionRouter.decide(mode: .alwaysApple, appleSupportsLanguage: true, whisperModelAvailable: false) == .apple)
    }

    @Test func alwaysWhisperPicksWhisperWhenModelPresent() throws {
        #expect(try TranscriptionRouter.decide(mode: .alwaysWhisper, appleSupportsLanguage: true, whisperModelAvailable: true) == .whisper)
    }

    @Test func alwaysWhisperThrowsWithoutModel() {
        #expect(throws: TranscriptionError.self) {
            try TranscriptionRouter.decide(mode: .alwaysWhisper, appleSupportsLanguage: true, whisperModelAvailable: false)
        }
    }

    @Test func automaticPrefersAppleWhenSupported() throws {
        #expect(try TranscriptionRouter.decide(mode: .automatic, appleSupportsLanguage: true, whisperModelAvailable: true) == .apple)
    }

    @Test func automaticFallsBackToWhisperWhenUnsupported() throws {
        #expect(try TranscriptionRouter.decide(mode: .automatic, appleSupportsLanguage: false, whisperModelAvailable: true) == .whisper)
    }

    @Test func automaticThrowsWhenUnsupportedAndNoModel() {
        #expect(throws: TranscriptionError.self) {
            try TranscriptionRouter.decide(mode: .automatic, appleSupportsLanguage: false, whisperModelAvailable: false)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RouterDecisionTests`
Expected: FAIL — `TranscriptionRouter` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Pure routing decision. Language resolution / auto-detect happens in the
/// Transcription router *before* calling this; here we only branch on facts.
enum TranscriptionRouter {
    static func decide(
        mode: TranscriptionEngineMode,
        appleSupportsLanguage: Bool,
        whisperModelAvailable: Bool
    ) throws -> TranscriptionBackendChoice {
        switch mode {
        case .alwaysApple:
            return .apple
        case .alwaysWhisper:
            guard whisperModelAvailable else { throw TranscriptionError.whisperModelNotInstalled }
            return .whisper
        case .automatic:
            if appleSupportsLanguage { return .apple }
            guard whisperModelAvailable else { throw TranscriptionError.whisperModelNotInstalled }
            return .whisper
        }
    }
}
```

- [ ] **Step 4: Add the new error case**

In `Sources/PalmierPro/Transcription/Transcription.swift`, extend `TranscriptionError` — add these cases and `errorDescription` arms:

```swift
    case whisperModelNotInstalled
    case whisperLoadFailed(String)
    case whisperTranscribeFailed(String)
```

```swift
        case .whisperModelNotInstalled:
            return "No Whisper model downloaded — add one in Settings › Transcription."
        case .whisperLoadFailed(let reason):
            return "Could not load the Whisper model: \(reason)"
        case .whisperTranscribeFailed(let reason):
            return "Whisper transcription failed: \(reason)"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter RouterDecisionTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Transcription/TranscriptionRouter.swift Sources/PalmierPro/Transcription/Transcription.swift Tests/PalmierProTests/Transcription/RouterDecisionTests.swift
git commit -m "feat: pure transcription backend routing decision"
```

---

## Task 4: Whisper model catalog (TDD)

**Files:**
- Create: `Sources/PalmierPro/Transcription/Whisper/WhisperModelCatalog.swift`
- Test: `Tests/PalmierProTests/Transcription/WhisperModelCatalogTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import PalmierPro

struct WhisperModelCatalogTests {
    @Test func hasThreeTiersWithUniqueIds() {
        let ids = WhisperModelCatalog.all.map(\.id)
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3)
    }

    @Test func everyModelHasNonEmptyRepoAndName() {
        for m in WhisperModelCatalog.all {
            #expect(!m.repo.isEmpty)
            #expect(!m.displayName.isEmpty)
            #expect(m.approxBytes > 0)
        }
    }

    @Test func defaultIsTurboAndInCatalog() {
        #expect(WhisperModelCatalog.all.contains { $0.id == WhisperModelCatalog.defaultModelId })
        #expect(WhisperModelCatalog.defaultModelId == "turbo")
    }

    @Test func languagesIncludeRussian() {
        #expect(WhisperModelCatalog.languages.contains("ru"))
        #expect(WhisperModelCatalog.languages.contains("en"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WhisperModelCatalogTests`
Expected: FAIL — `WhisperModelCatalog` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct WhisperModel: Identifiable, Sendable, Equatable {
    let id: String          // stable, persisted ("small"/"medium"/"turbo")
    let displayName: String
    let repo: String        // WhisperKit/HuggingFace repo variant
    let approxBytes: Int64
    let hint: String        // short speed/quality note

    var approxSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file)
    }
}

enum WhisperModelCatalog {
    static let all: [WhisperModel] = [
        WhisperModel(id: "small",  displayName: "Small",  repo: "openai_whisper-small",
                     approxBytes: 500_000_000,  hint: "Fastest, lowest accuracy"),
        WhisperModel(id: "medium", displayName: "Medium", repo: "openai_whisper-medium",
                     approxBytes: 1_500_000_000, hint: "Balanced"),
        WhisperModel(id: "turbo",  displayName: "Large v3 Turbo", repo: "openai_whisper-large-v3-turbo",
                     approxBytes: 1_500_000_000, hint: "Best accuracy (recommended)"),
    ]

    static let defaultModelId = "turbo"

    static func model(id: String) -> WhisperModel? { all.first { $0.id == id } }

    /// BCP-47 language codes Whisper handles. Whisper is multilingual (~99 languages);
    /// this is the subset surfaced in the picker as Whisper-capable, kept broad enough
    /// to cover Apple's gaps. Stored as language codes (no region).
    static let languages: Set<String> = [
        "en","zh","de","es","ru","ko","fr","ja","pt","tr","pl","ca","nl","ar","sv","it",
        "id","hi","fi","vi","he","uk","el","ms","cs","ro","da","hu","ta","no","th","ur",
        "hr","bg","lt","la","mi","ml","cy","sk","te","fa","lv","bn","sr","az","sl","kn",
        "et","mk","br","eu","is","hy","ne","mn","bs","kk","sq","sw","gl","mr","pa","si",
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WhisperModelCatalogTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Transcription/Whisper/WhisperModelCatalog.swift Tests/PalmierProTests/Transcription/WhisperModelCatalogTests.swift
git commit -m "feat: curated Whisper model catalog"
```

---

## Task 5: Whisper preferences (UserDefaults)

**Files:**
- Create: `Sources/PalmierPro/Transcription/Whisper/WhisperPreferences.swift`

Follows the `GenerationProvider.selected` pattern (`Sources/PalmierPro/Generation/Higgsfield/GenerationProvider.swift`).

- [ ] **Step 1: Write the file**

```swift
import Foundation

enum WhisperPreferences {
    private static let modeKey = "io.palmier.pro.transcription.engineMode"
    private static let activeModelKey = "io.palmier.pro.transcription.activeWhisperModel"

    static var engineMode: TranscriptionEngineMode {
        get {
            UserDefaults.standard.string(forKey: modeKey)
                .flatMap(TranscriptionEngineMode.init(rawValue:)) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// Active Whisper model id. Defaults to the catalog default; may point at a
    /// model that isn't downloaded yet (UI reflects download state separately).
    static var activeModelId: String {
        get { UserDefaults.standard.string(forKey: activeModelKey) ?? WhisperModelCatalog.defaultModelId }
        set { UserDefaults.standard.set(newValue, forKey: activeModelKey) }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Transcription/Whisper/WhisperPreferences.swift
git commit -m "feat: Whisper transcription preferences"
```

---

## Task 6: Neutral intermediate + transcript mapper (pure, TDD)

**Files:**
- Create: `Sources/PalmierPro/Transcription/Whisper/WhisperTranscriptMapper.swift`
- Test: `Tests/PalmierProTests/Transcription/WhisperTranscriptMapperTests.swift`

`RawTranscript` is Palmier-owned (no WhisperKit types), so the mapper is testable without the dependency.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import PalmierPro

struct WhisperTranscriptMapperTests {
    private func sample() -> RawTranscript {
        RawTranscript(
            detectedLanguage: "ru",
            segments: [
                RawSegment(text: "  Привет мир  ", start: 0.0, end: 1.5, words: [
                    RawWord(text: "Привет", start: 0.0, end: 0.7),
                    RawWord(text: "  мир ", start: 0.7, end: 1.5),
                ]),
                RawSegment(text: "  ", start: 1.5, end: 1.6, words: []),  // blank → dropped
            ]
        )
    }

    @Test func mapsSegmentsTrimmedAndDropsBlanks() {
        let r = WhisperTranscriptMapper.map(sample(), requestedLanguage: nil)
        #expect(r.segments.count == 1)
        #expect(r.segments[0].text == "Привет мир")
        #expect(r.segments[0].start == 0.0)
        #expect(r.segments[0].end == 1.5)
    }

    @Test func mapsWordsTrimmedAndMonotonic() {
        let r = WhisperTranscriptMapper.map(sample(), requestedLanguage: nil)
        #expect(r.words.map(\.text) == ["Привет", "мир"])
        for i in 1..<r.words.count {
            #expect((r.words[i].start ?? 0) >= (r.words[i-1].start ?? 0))
        }
    }

    @Test func prefersRequestedLanguageOverDetected() {
        let r = WhisperTranscriptMapper.map(sample(), requestedLanguage: "uk")
        #expect(r.language == "uk")
    }

    @Test func fallsBackToDetectedLanguage() {
        let r = WhisperTranscriptMapper.map(sample(), requestedLanguage: nil)
        #expect(r.language == "ru")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WhisperTranscriptMapperTests`
Expected: FAIL — `RawTranscript`/`WhisperTranscriptMapper` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Backend-neutral transcription shape produced by WhisperKitRunner. Deliberately
/// uses Palmier-owned names so no file mapping into TranscriptionResult needs to
/// import WhisperKit (whose TranscriptionResult/TranscriptionSegment names collide).
struct RawWord: Sendable { let text: String; let start: Double?; let end: Double? }
struct RawSegment: Sendable { let text: String; let start: Double; let end: Double; let words: [RawWord] }
struct RawTranscript: Sendable { let detectedLanguage: String?; let segments: [RawSegment] }

enum WhisperTranscriptMapper {
    static func map(_ raw: RawTranscript, requestedLanguage: String?) -> TranscriptionResult {
        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var fullText = ""

        for seg in raw.segments {
            let segText = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segText.isEmpty {
                segments.append(TranscriptionSegment(text: segText, start: seg.start, end: seg.end))
                fullText += (fullText.isEmpty ? "" : " ") + segText
            }
            for w in seg.words {
                let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                words.append(TranscriptionWord(text: t, start: w.start, end: w.end))
            }
        }

        return TranscriptionResult(
            text: fullText,
            language: requestedLanguage ?? raw.detectedLanguage,
            words: words,
            segments: segments
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WhisperTranscriptMapperTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Transcription/Whisper/WhisperTranscriptMapper.swift Tests/PalmierProTests/Transcription/WhisperTranscriptMapperTests.swift
git commit -m "feat: pure Whisper transcript mapper to TranscriptionResult"
```

---

## Task 7: WhisperKit runner (isolated dependency)

**Files:**
- Create: `Sources/PalmierPro/Transcription/Whisper/WhisperKitRunner.swift`

This is the **only** file that imports WhisperKit. It downloads/loads a model, transcribes, and returns `RawTranscript`. It never spells Palmier's `TranscriptionResult`/`TranscriptionSegment`.

> **API note:** WhisperKit's exact symbol names can drift between versions. The calls below match the 0.9.x API surface (`WhisperKit(WhisperKitConfig)`, `transcribe(audioPath:decodeOptions:)` → `[TranscriptionResult]` with `.segments`, each segment exposing `.words` of `WordTiming`, `WhisperKit.download(variant:from:progressCallback:)`, `detectLanguage(audioPath:)`). If a signature differs, adjust **only this file** — every other file depends on `RawTranscript`. Verify against the resolved version's headers (`.build/checkouts/WhisperKit/Sources/WhisperKit/...`).

- [ ] **Step 1: Write the file**

```swift
import Foundation
import WhisperKit

/// Wraps WhisperKit. Returns Palmier-neutral RawTranscript so the rest of the app
/// never sees WhisperKit's name-colliding TranscriptionResult/TranscriptionSegment.
actor WhisperKitRunner {
    private var pipe: WhisperKit?
    private var loadedRepo: String?

    /// Downloads a model variant into `destination`, reporting 0...1 progress.
    static func download(repo: String, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return try await WhisperKit.download(
            variant: repo,
            downloadBase: destination,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { p in progress(p.fractionCompleted) }
        )
    }

    /// Loads (from already-downloaded files at `modelFolder`) if not already loaded for this repo.
    private func ensureLoaded(repo: String, modelFolder: URL) async throws {
        if loadedRepo == repo, pipe != nil { return }
        do {
            let config = WhisperKitConfig(model: repo, modelFolder: modelFolder.path, download: false)
            pipe = try await WhisperKit(config)
            loadedRepo = repo
        } catch {
            pipe = nil; loadedRepo = nil
            throw TranscriptionError.whisperLoadFailed(error.localizedDescription)
        }
    }

    func unload() { pipe = nil; loadedRepo = nil }

    /// Detect the dominant language code (BCP-47 language, e.g. "ru").
    func detectLanguage(repo: String, modelFolder: URL, audioPath: String) async throws -> String? {
        try await ensureLoaded(repo: repo, modelFolder: modelFolder)
        guard let pipe else { return nil }
        let result = try? await pipe.detectLanguage(audioPath: audioPath)
        return result?.language
    }

    func transcribe(
        repo: String,
        modelFolder: URL,
        audioPath: String,
        language: String?
    ) async throws -> RawTranscript {
        try await ensureLoaded(repo: repo, modelFolder: modelFolder)
        guard let pipe else { throw TranscriptionError.whisperLoadFailed("pipeline unavailable") }

        let options = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: true
        )

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioPath: audioPath, decodeOptions: options)
        } catch {
            throw TranscriptionError.whisperTranscribeFailed(error.localizedDescription)
        }

        var rawSegments: [RawSegment] = []
        var detected: String?
        for r in results {
            detected = detected ?? r.language
            for seg in r.segments {
                let words: [RawWord] = (seg.words ?? []).map {
                    RawWord(text: $0.word, start: Double($0.start), end: Double($0.end))
                }
                rawSegments.append(RawSegment(
                    text: seg.text,
                    start: Double(seg.start),
                    end: Double(seg.end),
                    words: words
                ))
            }
        }
        return RawTranscript(detectedLanguage: detected, segments: rawSegments)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds. If the compiler flags an unknown WhisperKit symbol, correct it here against the resolved headers and rebuild (see API note above). Do not change `RawTranscript`.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Transcription/Whisper/WhisperKitRunner.swift
git commit -m "feat: isolated WhisperKit runner returning neutral RawTranscript"
```

---

## Task 8: Whisper model manager

**Files:**
- Create: `Sources/PalmierPro/Transcription/Whisper/WhisperModelManager.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import Observation

@MainActor
@Observable
final class WhisperModelManager {
    static let shared = WhisperModelManager()

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case error(String)
    }

    private(set) var states: [String: ModelState] = [:]   // keyed by model id
    var engineMode: TranscriptionEngineMode {
        didSet { WhisperPreferences.engineMode = engineMode }
    }
    var activeModelId: String {
        didSet { WhisperPreferences.activeModelId = activeModelId }
    }

    private let runner = WhisperKitRunner()
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    /// Application Support/PalmierPro/WhisperModels
    static let modelsDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/WhisperModels", isDirectory: true)

    static func folder(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.repo, isDirectory: true)
    }

    private init() {
        self.engineMode = WhisperPreferences.engineMode
        self.activeModelId = WhisperPreferences.activeModelId
        refreshStatesFromDisk()
    }

    /// Derive downloaded state from disk (presence of a non-empty model folder).
    func refreshStatesFromDisk() {
        for m in WhisperModelCatalog.all {
            if case .downloading = states[m.id] { continue }
            states[m.id] = Self.isDownloaded(m) ? .downloaded : .notDownloaded
        }
    }

    static func isDownloaded(_ model: WhisperModel) -> Bool {
        let folder = folder(for: model)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return !contents.isEmpty
    }

    /// True when the active model is downloaded and ready for the router.
    var activeModelAvailable: Bool {
        guard let m = WhisperModelCatalog.model(id: activeModelId) else { return false }
        return Self.isDownloaded(m)
    }

    func download(_ model: WhisperModel) {
        guard downloadTasks[model.id] == nil else { return }
        states[model.id] = .downloading(0)
        let folder = Self.folder(for: model)
        downloadTasks[model.id] = Task { [weak self] in
            do {
                _ = try await WhisperKitRunner.download(repo: model.repo, to: folder) { p in
                    Task { @MainActor in
                        if case .downloading = self?.states[model.id] { self?.states[model.id] = .downloading(p) }
                    }
                }
                await MainActor.run {
                    self?.states[model.id] = Self.isDownloaded(model) ? .downloaded : .error("Download incomplete")
                    self?.downloadTasks[model.id] = nil
                }
            } catch {
                await MainActor.run {
                    self?.states[model.id] = .error(error.localizedDescription)
                    self?.downloadTasks[model.id] = nil
                    try? FileManager.default.removeItem(at: folder)  // no silent partial models
                }
            }
        }
    }

    func cancelDownload(_ model: WhisperModel) {
        downloadTasks[model.id]?.cancel()
        downloadTasks[model.id] = nil
        try? FileManager.default.removeItem(at: Self.folder(for: model))
        states[model.id] = .notDownloaded
    }

    func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: Self.folder(for: model))
        states[model.id] = .notDownloaded
        Task { await runner.unload() }
    }

    func setActive(_ model: WhisperModel) {
        activeModelId = model.id
        Task { await runner.unload() }   // force reload of the newly-active model
    }

    var totalBytesOnDisk: Int64 {
        WhisperModelCatalog.all.reduce(0) { acc, m in
            guard Self.isDownloaded(m) else { return acc }
            let folder = Self.folder(for: m)
            let size = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path))?
                .compactMap { try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.size] as? Int64 }
                .reduce(0, +) ?? 0
            return acc + size
        }
    }

    /// Run a transcription with the active model. Throws if not downloaded.
    func transcribe(audioPath: String, language: String?) async throws -> RawTranscript {
        guard let model = WhisperModelCatalog.model(id: activeModelId), Self.isDownloaded(model) else {
            throw TranscriptionError.whisperModelNotInstalled
        }
        return try await runner.transcribe(
            repo: model.repo, modelFolder: Self.folder(for: model),
            audioPath: audioPath, language: language
        )
    }

    func detectLanguage(audioPath: String) async throws -> String? {
        guard let model = WhisperModelCatalog.model(id: activeModelId), Self.isDownloaded(model) else {
            throw TranscriptionError.whisperModelNotInstalled
        }
        return try await runner.detectLanguage(
            repo: model.repo, modelFolder: Self.folder(for: model), audioPath: audioPath
        )
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Transcription/Whisper/WhisperModelManager.swift
git commit -m "feat: Whisper model manager (download, state, active, delete)"
```

---

## Task 9: WhisperBackend (orchestrates manager + mapper)

**Files:**
- Create: `Sources/PalmierPro/Transcription/Backends/WhisperBackend.swift`

No `import WhisperKit`. Bridges the manager's `RawTranscript` into `TranscriptionResult`.

- [ ] **Step 1: Write the file**

```swift
import Foundation

struct WhisperBackend: TranscriptionBackend {
    func transcribe(fileURL: URL, language: Locale?, censorProfanity: Bool) async throws -> TranscriptionResult {
        // censorProfanity has no Whisper equivalent — ignored by design (see spec).
        let langCode = language?.language.languageCode?.identifier
        let raw = try await WhisperModelManager.shared.transcribe(audioPath: fileURL.path, language: langCode)
        return WhisperTranscriptMapper.map(raw, requestedLanguage: langCode)
    }

    func supportedLanguages() async -> Set<String> { WhisperModelCatalog.languages }

    /// Best-effort language detection for the router's auto path.
    func detectLanguage(fileURL: URL) async throws -> String? {
        try await WhisperModelManager.shared.detectLanguage(audioPath: fileURL.path)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/Transcription/Backends/WhisperBackend.swift
git commit -m "feat: WhisperBackend bridging manager output to TranscriptionResult"
```

---

## Task 10: AppleSpeechBackend (extract current logic)

**Files:**
- Create: `Sources/PalmierPro/Transcription/Backends/AppleSpeechBackend.swift`
- Modify: `Sources/PalmierPro/Transcription/Transcription.swift`

Move the existing SpeechTranscriber logic into the backend. The router (`Transcription`) keeps audio extraction and calls the backend with a decoded file.

- [ ] **Step 1: Create AppleSpeechBackend with the existing analysis logic**

```swift
import AVFoundation
import Foundation
import Speech

struct AppleSpeechBackend: TranscriptionBackend {
    func supportedLanguages() async -> Set<String> {
        let locales = await SpeechTranscriber.supportedLocales
        return Set(locales.compactMap { $0.language.languageCode?.identifier })
    }

    /// `fileURL` is a decoded 16 kHz mono PCM file (router-extracted). `language`
    /// is matched against supported locales; nil → best system locale.
    func transcribe(fileURL: URL, language: Locale?, censorProfanity: Bool) async throws -> TranscriptionResult {
        let supported = await SpeechTranscriber.supportedLocales
        let locale: Locale
        if let language, let match = Transcription.matchLocale(candidates: [language], supported: supported) {
            locale = match
        } else if language == nil, let auto = Transcription.bestSupportedLocale(from: supported) {
            locale = auto
        } else {
            throw TranscriptionError.unsupportedLocale((language ?? Locale.current).identifier(.bcp47))
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censorProfanity ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            do { try await install.downloadAndInstall() }
            catch { throw TranscriptionError.modelInstallFailed(error.localizedDescription) }
        }

        let audioFile: AVAudioFile
        do { audioFile = try AVAudioFile(forReading: fileURL) }
        catch { throw TranscriptionError.audioExtractionFailed(error.localizedDescription) }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultsTask = Task { () throws -> [SpeechTranscriber.Result] in
            var acc: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results { acc.append(result) }
            return acc
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            resultsTask.cancel()
            throw TranscriptionError.analysisFailed(error.localizedDescription)
        }
        let collected = try await resultsTask.value
        return Transcription.decodeAppleResults(collected, locale: locale)
    }
}
```

- [ ] **Step 2: Move the decoder onto Transcription and expose helpers**

In `Transcription.swift`, rename the existing `decodeResults(_:locale:)` to `decodeAppleResults(_:locale:)` and make it (and `bestSupportedLocale`, `matchLocale`) accessible to the backend (they are already `static` in the same module — just ensure no `private` on `decodeResults`; change `private static func decodeResults` to `static func decodeAppleResults`). Keep its body unchanged.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds (the old in-enum analysis path is replaced in Task 11; if duplicate-logic warnings/errors appear, they resolve once Task 11 rewires `transcribe`).

> If Step 3 fails because `Transcription.transcribe` still references removed internals, proceed to Task 11 in the same commit — Tasks 10 and 11 form one logical change. Commit at the end of Task 11.

---

## Task 11: Rewire Transcription as the router

**Files:**
- Modify: `Sources/PalmierPro/Transcription/Transcription.swift`

Keep the public API identical (`transcribe(fileURL:censorProfanity:preferredLocale:sourceRange:)`, `transcribeVideoAudio(...)`, `supportedLocales()`, `matchLocale`, `bestSupportedLocale`). Replace the body of `transcribe(fileURL:...)` (the no-range branch) to: extract audio → resolve language/detect → decide backend → delegate.

- [ ] **Step 1: Replace the no-range transcribe body**

Replace the analysis section of `transcribe(fileURL:censorProfanity:preferredLocale:sourceRange:)` (everything after the `sourceRange` early-return block) with:

```swift
        // Decode to 16 kHz mono PCM once; both backends consume this.
        let pcmURL = try await extractAudioTrack(from: fileURL)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        return try await route(pcmURL: pcmURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale)
```

Note: `extractAudioTrack` already accepts any decodable media (it uses `AudioTrackReader`); for an already-PCM `.caf` it re-reads/normalizes to 16 kHz mono, which is the format both backends want. `transcribeVideoAudio` keeps extracting from video first, then calls `transcribe(fileURL:)`, so it flows through `route` too.

- [ ] **Step 2: Add the route + language-resolution helpers**

Add to the `Transcription` enum:

```swift
    @MainActor
    static func route(pcmURL: URL, censorProfanity: Bool, preferredLocale: Locale?) async throws -> TranscriptionResult {
        let apple = AppleSpeechBackend()
        let whisper = WhisperBackend()
        let mode = WhisperModelManager.shared.engineMode
        let whisperAvailable = WhisperModelManager.shared.activeModelAvailable

        // Resolve the language to route on.
        let requestedLang = preferredLocale?.language.languageCode?.identifier
        var routingLang = requestedLang
        if mode == .automatic, routingLang == nil, whisperAvailable {
            // Auto-detect only when asked (no explicit language) and a model exists.
            routingLang = try? await whisper.detectLanguage(fileURL: pcmURL)
        }

        let appleLangs = await apple.supportedLanguages()
        // With no resolved language, Apple can still auto-pick from the system locale.
        let appleSupports = routingLang.map { appleLangs.contains($0) } ?? !appleLangs.isEmpty

        let choice = try TranscriptionRouter.decide(
            mode: mode, appleSupportsLanguage: appleSupports, whisperModelAvailable: whisperAvailable
        )

        let routeLocale = routingLang.map { Locale(identifier: $0) } ?? preferredLocale
        switch choice {
        case .apple:   return try await apple.transcribe(fileURL: pcmURL, language: routeLocale, censorProfanity: censorProfanity)
        case .whisper: return try await whisper.transcribe(fileURL: pcmURL, language: routeLocale, censorProfanity: censorProfanity)
        }
    }

    /// Apple ∪ Whisper languages, as Locales, for the caption picker.
    @MainActor
    static func availableLanguages() async -> [Locale] {
        let apple = await SpeechTranscriber.supportedLocales
        let appleCodes = Set(apple.compactMap { $0.language.languageCode?.identifier })
        let whisperOnly = WhisperModelCatalog.languages
            .subtracting(appleCodes)
            .map { Locale(identifier: $0) }
        return apple + whisperOnly
    }

    /// Whether a given locale is Whisper-only (Apple can't do it) — for the picker tag.
    static func isWhisperOnly(_ locale: Locale, appleCodes: Set<String>) -> Bool {
        guard let code = locale.language.languageCode?.identifier else { return false }
        return !appleCodes.contains(code) && WhisperModelCatalog.languages.contains(code)
    }
```

- [ ] **Step 3: Remove the now-dead in-enum analysis code**

Delete the SpeechTranscriber setup / AssetInventory / SpeechAnalyzer block that previously lived inside `transcribe` (it now lives in `AppleSpeechBackend`). Keep `extractAudioTrack`, `decodeAppleResults`, `matchLocale`, `bestSupportedLocale`, `supportedLocales`, and the `offsetting`/range logic.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds.

- [ ] **Step 5: Run the full transcription test group**

Run: `swift test --filter Transcription`
Expected: PASS (Tasks 3,4,6 tests still green).

- [ ] **Step 6: Commit (Tasks 10 + 11 together)**

```bash
git add Sources/PalmierPro/Transcription/Backends/AppleSpeechBackend.swift Sources/PalmierPro/Transcription/Transcription.swift
git commit -m "refactor: route transcription through Apple/Whisper backends"
```

---

## Task 12: Cache key includes backend + active model (TDD)

**Files:**
- Modify: `Sources/PalmierPro/Transcription/TranscriptCache.swift`
- Test: `Tests/PalmierProTests/Transcription/TranscriptCacheKeyTests.swift`

`TranscriptCache.key(for:)` currently hashes file identity only. Two engines yield different transcripts for one file, so the key must include a backend/model component.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PalmierPro

struct TranscriptCacheKeyTests {
    @Test func differentEngineTagYieldsDifferentKey() {
        let appleKey = TranscriptCache.cacheKeyComponent(engineTag: "apple")
        let whisperKey = TranscriptCache.cacheKeyComponent(engineTag: "whisper-turbo")
        #expect(appleKey != whisperKey)
    }

    @Test func sameEngineTagYieldsStableKey() {
        #expect(TranscriptCache.cacheKeyComponent(engineTag: "apple")
              == TranscriptCache.cacheKeyComponent(engineTag: "apple"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TranscriptCacheKeyTests`
Expected: FAIL — `cacheKeyComponent` not defined.

- [ ] **Step 3: Implement the engine tag and fold it into the key**

In `TranscriptCache`, add:

```swift
    /// Identifies which engine/model produced a cached transcript, so switching
    /// engines never returns a stale cross-engine result.
    @MainActor static func currentEngineTag() -> String {
        switch WhisperModelManager.shared.engineMode {
        case .alwaysApple: return "apple"
        case .alwaysWhisper: return "whisper-\(WhisperModelManager.shared.activeModelId)"
        case .automatic:
            return WhisperModelManager.shared.activeModelAvailable
                ? "auto-\(WhisperModelManager.shared.activeModelId)" : "auto-apple"
        }
    }

    nonisolated static func cacheKeyComponent(engineTag: String) -> String {
        SHA256.hash(data: Data(engineTag.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
```

Change `transcript(for:isVideo:range:)` to take the engine tag and weave it into the key. Update the private `key(for:)` to accept an `engineTag` parameter:

```swift
    func transcript(for url: URL, isVideo: Bool, range: ClosedRange<Double>?, engineTag: String) async throws -> TranscriptionResult {
        let key = Self.key(for: url, engineTag: engineTag)
        // ...unchanged body, using the new key...
    }
```

```swift
    private static func key(for url: URL, engineTag: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let identity = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)|\(engineTag)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
```

Update `hasCachedOnDisk(for:)` / `cachedOnDisk(for:)` to also take `engineTag` (callers in Step 4).

- [ ] **Step 4: Update the three call sites**

Each caller computes the tag on the main actor and passes it:

`ToolExecutor+Timeline.swift` (lines ~368, ~484, ~577) and `SearchIndexCoordinator.swift` (~193) and `EditorViewModel+Captions.swift` (~133):

```swift
let engineTag = await MainActor.run { TranscriptCache.currentEngineTag() }
... try await TranscriptCache.shared.transcript(for: url, isVideo: isVideo, range: range, engineTag: engineTag)
```

For any `TranscriptCache.hasCachedOnDisk(for:)` / `cachedOnDisk(for:)` calls, pass `engineTag:` likewise (grep: `grep -rn "hasCachedOnDisk\|cachedOnDisk" Sources`).

- [ ] **Step 5: Run tests + build**

Run: `swift test --filter TranscriptCacheKeyTests && swift build`
Expected: PASS, then builds.

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Transcription/TranscriptCache.swift Tests/PalmierProTests/Transcription/TranscriptCacheKeyTests.swift Sources/PalmierPro/Agent/Tools/ToolExecutor+Timeline.swift Sources/PalmierPro/Search/SearchIndexCoordinator.swift Sources/PalmierPro/Editor/ViewModel/EditorViewModel+Captions.swift
git commit -m "feat: include engine/model in transcript cache key"
```

---

## Task 13: availableLanguages union test

**Files:**
- Test: `Tests/PalmierProTests/Transcription/AvailableLanguagesTests.swift`

- [ ] **Step 1: Write the test**

```swift
import Testing
import Foundation
@testable import PalmierPro

struct AvailableLanguagesTests {
    @Test func whisperOnlyDetectionFlagsRussianWhenAppleLacksIt() {
        let appleCodes: Set<String> = ["en", "es", "fr"]   // pretend Apple lacks ru
        #expect(Transcription.isWhisperOnly(Locale(identifier: "ru"), appleCodes: appleCodes))
        #expect(!Transcription.isWhisperOnly(Locale(identifier: "en"), appleCodes: appleCodes))
    }

    @Test func nonWhisperLanguageIsNotFlagged() {
        let appleCodes: Set<String> = ["en"]
        // "zz" is neither Apple nor Whisper
        #expect(!Transcription.isWhisperOnly(Locale(identifier: "zz"), appleCodes: appleCodes))
    }
}
```

- [ ] **Step 2: Run test**

Run: `swift test --filter AvailableLanguagesTests`
Expected: PASS (2 tests).

- [ ] **Step 3: Commit**

```bash
git add Tests/PalmierProTests/Transcription/AvailableLanguagesTests.swift
git commit -m "test: Whisper-only language detection for picker"
```

---

## Task 14: Settings — TranscriptionPane

**Files:**
- Create: `Sources/PalmierPro/Settings/TranscriptionPane.swift`
- Modify: `Sources/PalmierPro/Settings/SettingsView.swift`

- [ ] **Step 1: Add the settings tab**

In `SettingsView.swift`, add to `enum SettingsTab`:

```swift
    case transcription
```

`title` arm: `case .transcription: return "Transcription"`
`icon` arm (uses the `SettingsTab` icon switch): `case .transcription: return "captions.bubble"`
In `SettingsDetail`'s `switch tab` (after `.models`): `case .transcription: TranscriptionPane()`

Place `.transcription` in `allCases` order right after `.models` (the enum case order defines sidebar order — add the case between `models` and `agent`).

- [ ] **Step 2: Create the pane**

```swift
import SwiftUI

struct TranscriptionPane: View {
    @State private var manager = WhisperModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            engineSection
            Divider().overlay(AppTheme.Border.subtleColor)
            modelsSection
            footer
        }
        .onAppear { manager.refreshStatesFromDisk() }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Engine").font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
            Picker("", selection: Binding(get: { manager.engineMode }, set: { manager.engineMode = $0 })) {
                ForEach(TranscriptionEngineMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("Automatic uses Apple on-device for supported languages and Whisper for the rest (e.g. Russian).")
                .font(.system(size: AppTheme.FontSize.xs)).foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Whisper Models").font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
            ForEach(WhisperModelCatalog.all) { model in
                modelRow(model)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModel) -> some View {
        let state = manager.states[model.id] ?? .notDownloaded
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(model.displayName).font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    if case .downloaded = state, manager.activeModelId == model.id {
                        Text("Active").font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
                Text("\(model.approxSizeDescription) · \(model.hint)")
                    .font(.system(size: AppTheme.FontSize.xs)).foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Spacer()
            trailingControl(model, state: state)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private func trailingControl(_ model: WhisperModel, state: WhisperModelManager.ModelState) -> some View {
        switch state {
        case .notDownloaded:
            Button("Download") { manager.download(model) }
        case .downloading(let p):
            HStack(spacing: AppTheme.Spacing.xs) {
                ProgressView(value: p).frame(width: 100)
                Button("Cancel") { manager.cancelDownload(model) }
            }
        case .downloaded:
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(manager.activeModelId == model.id ? "Selected" : "Use") { manager.setActive(model) }
                    .disabled(manager.activeModelId == model.id)
                Button(role: .destructive) { manager.delete(model) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
            }
        case .error(let msg):
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(msg).font(.system(size: AppTheme.FontSize.xs)).foregroundStyle(AppTheme.Status.errorColor)
                Button("Retry") { manager.download(model) }
            }
        }
    }

    private var footer: some View {
        Text("Downloaded models use \(ByteCountFormatter.string(fromByteCount: manager.totalBytesOnDisk, countStyle: .file)) on disk.")
            .font(.system(size: AppTheme.FontSize.xs)).foregroundStyle(AppTheme.Text.secondaryColor)
    }
}
```

> Verify the exact `AppTheme` symbols used (`AppTheme.Status.errorColor`, `AppTheme.Text.secondaryColor`, `AppTheme.FontSize.xxs`) exist; if a name differs, use the nearest existing constant per `Sources/PalmierPro/UI/AppTheme.swift` — never hardcode values.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Settings/TranscriptionPane.swift Sources/PalmierPro/Settings/SettingsView.swift
git commit -m "feat: Settings Transcription pane (engine mode + model downloads)"
```

---

## Task 15: Caption picker shows Apple ∪ Whisper languages

**Files:**
- Modify: `Sources/PalmierPro/MediaPanel/CaptionsTab/CaptionTab.swift`

- [ ] **Step 1: Source the picker from availableLanguages + tag Whisper-only**

Replace the `.task` that fills `supportedLocales`:

```swift
        .task {
            guard supportedLocales.isEmpty else { return }
            let langs = await Transcription.availableLanguages()
            appleCodes = await Set(Transcription.supportedLocales().compactMap { $0.language.languageCode?.identifier })
            supportedLocales = langs.sorted { languageName($0) < languageName($1) }
        }
```

Add the state near the other `@State` declarations:

```swift
    @State private var appleCodes: Set<String> = []
```

Update the language menu's per-locale button label to tag Whisper-only entries:

```swift
                        ForEach(supportedLocales, id: \.identifier) { loc in
                            Button {
                                locale = loc
                            } label: {
                                if Transcription.isWhisperOnly(loc, appleCodes: appleCodes) {
                                    Text("\(languageName(loc))  ·  Whisper")
                                } else {
                                    Text(languageName(loc))
                                }
                            }
                        }
```

(The existing "Auto" button at the top stays — it maps to `locale = nil`, which the router treats as auto-detect.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/PalmierPro/MediaPanel/CaptionsTab/CaptionTab.swift
git commit -m "feat: caption language picker includes Whisper languages"
```

---

## Task 16: Agent add_captions accepts Whisper languages

**Files:**
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor+Captions.swift`
- Modify: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`

- [ ] **Step 1: Match against Apple ∪ Whisper instead of Apple-only**

In `ToolExecutor+Captions.swift`, replace the language-validation block (currently rejecting any non-Apple language):

```swift
        var locale: Locale?
        if let lang = args.string("language") {
            let candidate = Locale(identifier: lang)
            let langCode = candidate.language.languageCode?.identifier
            let appleLangs = await Transcription.supportedLocales()
            let appleMatch = Transcription.matchLocale(candidates: [candidate], supported: appleLangs)
            let whisperOK = langCode.map { WhisperModelCatalog.languages.contains($0) } ?? false
            guard appleMatch != nil || whisperOK else {
                throw ToolError("add_captions: language '\(lang)' is not supported by Apple on-device or Whisper.")
            }
            locale = appleMatch ?? candidate
        }
```

The router (`Transcription.route`) decides Apple vs Whisper from this locale; if Whisper is needed but no model is downloaded it throws `.whisperModelNotInstalled`, whose message tells the user to download one.

- [ ] **Step 2: Update the tool schema description**

In `ToolDefinitions.swift` (`add_captions`, the `language` property, ~line 365), replace the description:

```swift
                    "language": ["type": "string", "description": "Optional BCP-47 language of the speech (e.g. 'es', 'ja', 'ru'). Defaults to the system language. Languages Apple doesn't support on-device (e.g. Russian) are transcribed with Whisper if a Whisper model is downloaded in Settings › Transcription; otherwise the tool errors asking the user to download one. Set this when the footage isn't in the system language."],
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Agent/Tools/ToolExecutor+Captions.swift Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift
git commit -m "feat: add_captions accepts Whisper languages and routes accordingly"
```

---

## Task 17: Full test + build verification

**Files:** none (verification)

- [ ] **Step 1: Run the whole transcription test group**

Run: `swift test --filter Transcription`
Expected: PASS — RouterDecision (6), WhisperModelCatalog (4), WhisperTranscriptMapper (4), TranscriptCacheKey (2), AvailableLanguages (2).

- [ ] **Step 2: Full build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Full test suite (regression)**

Run: `swift test`
Expected: existing suites still pass (no regressions from the cache-key signature change).

- [ ] **Step 4: Manual integration checklist (documented, not automated)**

Document outcome in the PR description:
1. Open Settings › Transcription → download **Large v3 Turbo** (progress shows, completes, becomes Active).
2. Import a Russian-language clip; in the Captions tab pick **Russian (· Whisper)** (or Auto) → Generate.
3. Confirm captions appear with sensible word timing; run `get_transcript` (via agent/MCP) and confirm Russian words with frames.
4. Switch engine to **Always Apple**, re-generate on the same clip → expect the unsupported-language error (no crash).
5. Delete the model → Settings reflects `notDownloaded`; disk total drops.

- [ ] **Step 5: Commit any doc updates**

```bash
git add -A
git commit -m "test: verify Whisper backend end-to-end" --allow-empty
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** protocol/router (Tasks 2,3,10,11) · WhisperKit + models (1,4,5,7,8,9) · settings UI (14) · picker + Auto-detect (11,15) · agent path (16) · data mapping (6) · cache key (12) · errors (3,8) · tests (3,4,6,12,13,17). All spec sections map to a task.
- **WhisperKit API drift** is the main risk; it is contained to `WhisperKitRunner.swift` by design — fix signatures there only.
- **Profanity** is intentionally a no-op for Whisper (spec non-goal).
- **Type names** are consistent across tasks: `RawTranscript`/`RawSegment`/`RawWord`, `TranscriptionBackendChoice`, `TranscriptionEngineMode`, `WhisperModelManager.shared`, `WhisperPreferences`, `TranscriptCache.currentEngineTag()`.
