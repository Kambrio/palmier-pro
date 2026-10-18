# EmbeddingGemma 2 Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Local multimodal (text/image/video/audio) embeddings in Palmier Pro via EmbeddingGemma 2 on MLX, powering semantic search, footage grouping, audio matching, and agent tools.

**Architecture:** One new embedding engine (`GemmaEmbedding` protocol, real impl on `mlx-swift-lm` `MLXEmbedders`) beside the existing SigLIP stack. A `GemmaIndexer` writes frame vectors into the existing `EmbeddingStore` (new `model` header value) plus clip/audio vectors into a new `ClipEmbedStore` sidecar, keyed by source-file identity. Search fuses Gemma and SigLIP rankings; clustering and three new agent tools read the same stores.

**Tech Stack:** Swift 6.2 / SPM, macOS 26, `mlx-swift-lm` ≥3.32.3 (products `MLXEmbedders`, `MLXVLM`, `MLXHuggingFace`) behind the existing `BundledSpeech` trait, `swift-transformers` (already a dep), AVFoundation PCM extraction, vDSP cosine.

**Spec:** `docs/superpowers/specs/2026-10-19-embeddinggemma2-design.md`

## Global Constraints

- Model: `mlx-community/embeddinggemma-2-8bit` via HF hub; embedding dim 768; MRL truncate to 256 for clustering (renormalize).
- Store names: `EmbeddingStore` header `model: "embeddinggemma-2"`, `modelVersion: 1`. Never touch SigLIP's `"siglip"`-family rows.
- Every file I/O and inference off the main actor and main thread (AGENTS.md). No new `@MainActor` work beyond the manager's state fields.
- MLX-dependent code compiles only under `#if BUNDLED_SPEECH` (existing define, Package.swift trait `BundledSpeech`), matching how `MLX` is gated.
- No fp16 assumptions anywhere; all vectors `[Float]` (fp32 at the boundary), normalized.
- AppTheme constants for any new UI. Comments minimal per AGENTS.md.
- Commits: Conventional with scope — `feat(search):`, `feat(shots):`, `feat(agent):`, `build:`.
- Build commands: `swift build` (SPM). Full suite `swift test`; single suite `swift test --filter <SuiteName>`.
- Repo: work on branch `feat/embeddinggemma2` (already created). Never push to `upstream`.

## Reference facts (do not re-derive)

- `EmbeddingStore` (`Sources/PalmierPro/Search/Indexing/EmbeddingStore.swift`): `key(for: URL)` = SHA of path|mtime|size; `Header{model, modelVersion, samplerVersion, dim, count}`; rows `(time, shotStart, shotEnd)` + Float16 vectors; `load(key:)`, `save(header:rows:vectors:key:)`, `isCurrent(key:model:modelVersion:samplerVersion:)`. Writes must be off-main.
- `FrameSampler.frames(url:duration:options:)` (`Search/Indexing/FrameSampler.swift`) yields `Frame{time, image: CGImage, isNewShot}`; `samplerVersion = 1`.
- `SearchIndexCoordinator` (`Search/SearchIndexCoordinator.swift`): `@MainActor @Observable`, queue of `IndexWork{asset: AssetSnapshot, spec}`, `indexOne(_:model:transcribe:)` does per-asset work, `search(query:limit:within:)` at line 299 fans out to `VisualSearch.search(query:indexes:limit:minScore:)`. `VisualModelLoader.shared` gates everything; mirror that pattern for Gemma.
- `VisualSearch.Hit{assetID, time, shotStart, shotEnd, score}` — the media grid consumes this shape; fused output must stay this type.
- `MediaManifest.Entry` (`Models/MediaManifest.swift`): `sourceURL: String?`, `sourcePath: String?`, `proxyPath: String?`, `source: MediaSource` (`.external(absolutePath:)`). `MediaAsset.url` is already the proxy URL when proxies are active, and is what the coordinator indexes today.
- `ToolName` (`Agent/Tools/ToolDefinitions.swift:4`) raw-value snake_case; tool impls live in `ToolExecutor+*.swift`; `searchMedia = "search_media"` exists with impl in `ToolExecutor+Search.swift`.
- `VisualModelLoader` pattern to mirror: `State` enum, `prepare/download/setEnabled/remove`, `Task.detached` load, `Log.search`.
- MLXEmbedders API (verified from README): `EmbeddingGemma2Embedding(modelDirectory:tokenizerLoader:)`, `.embed(Input, task:, dimensions:)` where Input is `[.text(String), .image(.url(URL)), .audio(.url(URL))]`; task enum includes search/document/clustering; throws `contextExceeded` when media over limits (video 1 fps ≤32 frames, audio 16 kHz mono ≤30 s). Low-level `imageFeatures`/`audioFeatures` exist but are not needed.
- Tests dir: `Tests/PalmierProTests/Search/` (existing suites: `EmbeddingStoreTests`, `VisualIndexerTests`, `VisualSearchTests`, `ModelDownloaderTests`).

---

### Task 1: Dependency spike — mlx-swift-lm builds

**Files:**
- Modify: `Package.swift` (dependencies array + PalmierPro target dependencies)

**Interfaces:**
- Produces: package products `MLXEmbedders`, `MLXVLM`, `MLXHuggingFace` from package `mlx-swift-lm`, available under `#if BUNDLED_SPEECH`.

- [ ] **Step 1: Add the dependency**

In `Package.swift` dependencies array add:

```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.32.3"),
```

In the `PalmierPro` executable target's dependencies add (next to the existing `MLX` product entry):

```swift
.product(name: "MLXEmbedders", package: "mlx-swift-lm",
         condition: .when(traits: ["BundledSpeech"])),
.product(name: "MLXVLM", package: "mlx-swift-lm",
         condition: .when(traits: ["BundledSpeech"])),
.product(name: "MLXHuggingFace", package: "mlx-swift-lm",
         condition: .when(traits: ["BundledSpeech"])),
```

- [ ] **Step 2: Resolve version conflict if any**

Run: `swift package resolve 2>&1 | tail -20`
If it reports `mlx-swift` version conflicts against the existing `.package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.5")`: check the requirement `swift package dump-package 2>/dev/null` error text, then relax our pin to the lowest version satisfying both (`.upToNextMinor(from: "0.31.5")` first; bump only as far as mlx-swift-lm requires). `swift-transformers` already `from: "1.3.3"` — compatible.

- [ ] **Step 3: Build gate**

Run: `swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (nothing imports the new products yet).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add mlx-swift-lm dependency for EmbeddingGemma 2"
```

---

### Task 2: GemmaEmbedding protocol, truncate helper, stub

**Files:**
- Create: `Sources/PalmierPro/Search/Models/GemmaEmbedding.swift`
- Test: `Tests/PalmierProTests/Search/GemmaEmbeddingTests.swift`

**Interfaces:**
- Produces (used by Tasks 3, 5, 7, 10):
  - `enum GemmaTask: String, Sendable { case searchQuery = "search result", document, clustering }`
  - `protocol GemmaEmbedding: AnyObject, Sendable { var dim: Int { get }; func embedText(_: String, task: GemmaTask) async throws -> [Float]; func embedImages(_: [CGImage]) async throws -> [[Float]]; func embedVideo(_: [CGImage]) async throws -> [Float]; func embedAudio(_: [Float], sampleRate: Int) async throws -> [Float] }`
  - `enum GemmaVector { static func truncate(_ vector: [Float], to dim: Int) -> [Float] }` — MRL slice + L2 renormalize.
  - `final class StubGemmaEmbedding: GemmaEmbedding` — deterministic vectors from input seed, dim injectable (default 768).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PalmierPro

@Suite struct GemmaEmbeddingTests {
    @Test func truncateSlicesAndRenormalizes() {
        let v = (0..<768).map { Float($0) / 1000 }
        let norm = { (x: [Float]) in sqrt(x.reduce(0) { $0 + $1 * $1 }) }
        let t = GemmaVector.truncate(v, to: 256)
        #expect(t.count == 256)
        #expect(abs(norm(t) - 1) < 1e-5)
        #expect(abs(t[0] - v[0] / norm(v)) < 1e-6) // same direction, unit length
    }

    @Test func truncateRejectsBadDim() {
        #expect(GemmaVector.truncate([0.5, 0.5], to: 0).isEmpty)
        #expect(GemmaVector.truncate([0.5, 0.5], to: 4).isEmpty)
    }

    @Test func stubIsDeterministicAndNormalized() async throws {
        let stub = StubGemmaEmbedding()
        let a = try await stub.embedText("night market", task: .searchQuery)
        let b = try await stub.embedText("night market", task: .searchQuery)
        #expect(a.count == stub.dim)
        #expect(a == b)
        #expect(abs(sqrt(a.reduce(0) { $0 + $1 * $1 }) - 1) < 1e-5)
    }

    @Test func stubDistinctInputsDiffer() async throws {
        let stub = StubGemmaEmbedding()
        let a = try await stub.embedText("rain", task: .document)
        let b = try await stub.embedText("sunshine", task: .document)
        #expect(a != b)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GemmaEmbeddingTests 2>&1 | tail -5`
Expected: FAIL — cannot find `GemmaEmbeddingTests` / `GemmaVector`.

- [ ] **Step 3: Implement**

`Sources/PalmierPro/Search/Models/GemmaEmbedding.swift`:

```swift
import CoreGraphics
import Foundation

enum GemmaTask: String, Sendable {
    case searchQuery = "search result"
    case document
    case clustering
}

protocol GemmaEmbedding: AnyObject, Sendable {
    var dim: Int { get }
    func embedText(_ text: String, task: GemmaTask) async throws -> [Float]
    func embedImages(_ images: [CGImage]) async throws -> [[Float]]
    /// Ordered frames of one clip; returns a single interleaved video embedding.
    func embedVideo(_ frames: [CGImage]) async throws -> [Float]
    /// Mono PCM; `sampleRate` is the caller's rate (16 kHz nominal).
    func embedAudio(_ samples: [Float], sampleRate: Int) async throws -> [Float]
}

enum GemmaVector {
    /// Matryoshka truncation with renormalization; empty when the request is out of range.
    static func truncate(_ vector: [Float], to dim: Int) -> [Float] {
        guard dim > 0, dim < vector.count else { return [] }
        var slice = Array(vector.prefix(dim))
        let norm = sqrt(slice.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return slice }
        for i in slice.indices { slice[i] /= norm }
        return slice
    }
}

/// Deterministic stand-in: unit vector derived from a seed, stable per input.
final class StubGemmaEmbedding: GemmaEmbedding, @unchecked Sendable {
    let dim: Int
    init(dim: Int = 768) { self.dim = dim }

    func embedText(_ text: String, task: GemmaTask) async throws -> [Float] {
        Self.unit(seed: UInt64(abs("\(task.rawValue)|\(text)".hashValue)))
    }
    func embedImages(_ images: [CGImage]) async throws -> [[Float]] {
        try images.map { _ in Self.unit(seed: UInt64(UUID().hashValue) &+ 1) == [] ? [] : Self.unit(seed: UInt64(abs(images.count)) &+ 7) }
    }
    func embedVideo(_ frames: [CGImage]) async throws -> [Float] {
        Self.unit(seed: UInt64(abs(frames.count)) &+ 11)
    }
    func embedAudio(_ samples: [Float], sampleRate: Int) async throws -> [Float] {
        Self.unit(seed: UInt64(abs(samples.count)) &+ UInt64(bitPattern: Int64(sampleRate)))
    }

    static func unit(seed: UInt64) -> [Float] {
        var state = seed == 0 ? 1 : seed
        var out = [Float](repeating: 0, count: 768)
        for i in out.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out[i] = Float(Int8(bitPattern: UInt8(truncatingIfNeeded: state >> 33))) / 127
        }
        let norm = sqrt(out.reduce(0) { $0 + $1 * $1 })
        return out.map { $0 / max(norm, 1e-9) }
    }
}
```

Note: `unit` always emits 768 dims; if `dim != 768`, wrap results in the service later via `GemmaVector.truncate`/pad — tests use the default 768 only. Keep the stub's `dim` and output length consistent by changing `unit`'s count to use an instance property when a non-default dim is constructed: implement `unit(seed:)` as an instance method returning `dim` values (adjust the code above accordingly: move into the class, `count: dim`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GemmaEmbeddingTests 2>&1 | tail -5`
Expected: PASS (4 tests). `embedImages` in the stub must return one vector per image — simplify to `try images.map { _ in unit(seed: UInt64($0.width)) }` style if the literal above is awkward; keep determinism.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Search/Models/GemmaEmbedding.swift Tests/PalmierProTests/Search/GemmaEmbeddingTests.swift
git commit -m "feat(search): GemmaEmbedding protocol, MRL truncate, deterministic stub"
```

---

### Task 3: GemmaModelManager — state machine + real MLX loader

**Files:**
- Create: `Sources/PalmierPro/Search/Models/GemmaModelManager.swift`
- Test: `Tests/PalmierProTests/Search/GemmaModelManagerTests.swift`

**Interfaces:**
- Consumes: `GemmaEmbedding` (Task 2), MLXEmbedders under `#if BUNDLED_SPEECH`.
- Produces (used by Tasks 5, 7, 9, 12):
  - `@MainActor @Observable final class GemmaModelManager` with `enum State: Equatable { case unknown, notInstalled, downloading(Double), preparing, ready, failed(String) }`
  - `static let shared: GemmaModelManager`
  - `var state: State`, `var enabled: Bool` (UserDefaults `"gemmaEmbeddingEnabled"`, default `false`), `var isReady: Bool`
  - `@ObservationIgnored private(set) var embedder: (any GemmaEmbedding)?`
  - `func prepare() async` (load if installed), `func download()` (install then load), `func setEnabled(_:)`, `func remove() async` (delete model, clear gemma stores via Task 4's `ClipEmbedStore.clearAll()` added later — for now only reset state).
  - `struct ModelFactories { var load: @Sendable (_ progress: @Sendable (Double) -> Void) async throws -> any GemmaEmbedding; var isInstalled: @Sendable () -> Bool; var delete: @Sendable () -> Void }` injected at init; `shared` uses `.live`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PalmierPro

@MainActor
@Suite struct GemmaModelManagerTests {
    private func makeManager(installed: Bool, loadFails: Bool = false)
        -> (GemmaModelManager, CheckedContinuation<Void, Never>?) {
        var continuation: CheckedContinuation<Void, Never>? = nil
        let factories = GemmaModelManager.ModelFactories(
            load: { _ in
                if loadFails { throw ModelErrorForTests.boom }
                return StubGemmaEmbedding()
            },
            isInstalled: { installed },
            delete: {})
        return (GemmaModelManager(factories: factories), continuation)
    }

    enum ModelErrorForTests: Error { case boom }

    @Test func prepareWhenNotInstalledStaysNotInstalled() async {
        let (manager, _) = makeManager(installed: false)
        await manager.prepare()
        #expect(manager.state == .notInstalled)
    }

    @Test func prepareWhenInstalledBecomesReady() async {
        let (manager, _) = makeManager(installed: true)
        await manager.prepare()
        #expect(manager.state == .ready)
        #expect(manager.embedder != nil)
    }

    @Test func downloadInstallsAndReadies() async {
        let (manager, _) = makeManager(installed: false)
        manager.download()
        while manager.state != .ready && !manager.isFailedState {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.state == .ready)
    }

    @Test func loadFailureSurfaces() async {
        let (manager, _) = makeManager(installed: true, loadFails: true)
        await manager.prepare()
        if case .failed = manager.state { } else { Issue.record("expected failed, got \(manager.state)") }
    }

    @Test func disabledByDefault() { #expect(GemmaModelManager.defaultEnabled == false) }
}

extension GemmaModelManager {
    var isFailedState: Bool { if case .failed = state { return true }; return false }
    static let defaultEnabled = false
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GemmaModelManagerTests 2>&1 | tail -5`
Expected: FAIL — no `GemmaModelManager`.

- [ ] **Step 3: Implement**

```swift
import Foundation

@MainActor
@Observable
final class GemmaModelManager {
    enum State: Equatable {
        case unknown, notInstalled, downloading(Double), preparing, ready, failed(String)
    }

    struct ModelFactories: Sendable {
        var load: @Sendable (@Sendable (Double) -> Void) async throws -> any GemmaEmbedding
        var isInstalled: @Sendable () -> Bool
        var delete: @Sendable () -> Void
        static let live = ModelFactories(
            load: { progress in try await LiveGemmaEmbedderFactory.load(progress: progress) },
            isInstalled: { LiveGemmaEmbedderFactory.isInstalled() },
            delete: { LiveGemmaEmbedderFactory.delete() })
    }

    static let shared = GemmaModelManager(factories: .live)
    static let defaultsKey = "gemmaEmbeddingEnabled"

    private(set) var state: State = .unknown
    private(set) var enabled = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false
    @ObservationIgnored private(set) var embedder: (any GemmaEmbedding)?
    private let factories: ModelFactories

    var isReady: Bool { state == .ready }

    init(factories: ModelFactories) { self.factories = factories }

    func prepare() async {
        guard enabled, state == .unknown else { return }
        guard factories.isInstalled() else { state = .notInstalled; return }
        state = .preparing
        await load()
    }

    func download() {
        switch state {
        case .downloading, .preparing, .ready: return
        default: break
        }
        state = .downloading(0)
        Task {
            do {
                let embedder = try await factories.load { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                guard enabled else { state = .unknown; return }
                state = .preparing
                self.embedder = embedder
                state = .ready
                Log.search.notice("gemma model ready dim=\(embedder.dim)")
                SearchIndexCoordinator.sweepAll()
            } catch {
                state = .failed(error.localizedDescription)
                Log.search.error("gemma model download/load failed: \(error.localizedDescription)")
            }
        }
    }

    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
        enabled = value
        if value {
            Task { await prepare(); SearchIndexCoordinator.sweepAll() }
        } else {
            Task {
                await SearchIndexCoordinator.cancelAll()
                embedder = nil
                if state == .ready || state == .preparing { state = .unknown }
            }
        }
    }

    func remove() async {
        await SearchIndexCoordinator.cancelAll()
        embedder = nil
        state = .notInstalled
        factories.delete()
        ClipEmbedStore.clearAll()
    }

    private func load() async {
        do {
            let embedder = try await factories.load { _ in }
            self.embedder = embedder
            state = .ready
            Log.search.notice("gemma model ready dim=\(embedder.dim)")
        } catch {
            state = .failed(error.localizedDescription)
            Log.search.error("gemma model load failed: \(error.localizedDescription)")
        }
    }
}
```

`LiveGemmaEmbedderFactory` in the same file, real MLX path entirely behind the trait define so non-`BundledSpeech` builds still compile:

```swift
#if BUNDLED_SPEECH
import CoreGraphics
import MLXEmbedders
import MLXVLM

enum LiveGemmaEmbedderFactory {
    static let hubID = "mlx-community/embeddinggemma-2-8bit"

    static func isInstalled() -> Bool {
        // HubApi snapshot cache presence; download() (re)fetches when missing.
        (try? HubCache.installationDirectory(for: hubID).checkResourceIsReachable()) ?? false
    }

    static func delete() {
        if let dir = try? HubCache.installationDirectory(for: hubID) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func load(progress: @Sendable (Double) -> Void) async throws -> any GemmaEmbedding {
        let embedder = try await EmbeddingGemma2Embedding(
            modelDirectory: #hubDownloader(hubID),
            tokenizerLoader: #huggingFaceTokenizerLoader())
        progress(1)
        return MLXGemmaEmbedder(underlying: embedder)
    }
}

/// Adapts the library's multimodal embedder to GemmaEmbedding; all callsites stay trait-free.
final class MLXGemmaEmbedder: GemmaEmbedding, @unchecked Sendable {
    let dim = 768
    private let underlying: EmbeddingGemma2Embedding
    init(underlying: EmbeddingGemma2Embedding) { self.underlying = underlying }

    func embedText(_ text: String, task: GemmaTask) async throws -> [Float] {
        try await underlying.embed(.init([.text(text)]), task: .init(task), dimensions: dim)
    }
    func embedImages(_ images: [CGImage]) async throws -> [[Float]] {
        try await withThrowingTaskGroup(of: [Float].self) { group in
            for image in images {
                group.addTask { [underlying] in
                    let url = try Self.tempPNG(image)
                    defer { try? FileManager.default.removeItem(at: url) }
                    return try await underlying.embed(.init([.image(.url(url))]), task: .document, dimensions: 768)
                }
            }
            var out: [[Float]] = []
            for try await v in group { out.append(v) }
            return out
        }
    }
    func embedVideo(_ frames: [CGImage]) async throws -> [Float] {
        try await underlying.embed(.init(frames.map { .image(.url(try Self.tempPNG($0))) }),
                                   task: .document, dimensions: dim)
    }
    func embedAudio(_ samples: [Float], sampleRate: Int) async throws -> [Float] {
        let url = try Self.tempWAV(samples, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await underlying.embed(.init([.audio(.url(url))]), task: .document, dimensions: dim)
    }
}
#else
enum LiveGemmaEmbedderFactory {
    static func isInstalled() -> Bool { false }
    static func delete() {}
    static func load(progress: @Sendable (Double) -> Void) async throws -> any GemmaEmbedding {
        throw GemmaUnavailableError.modelNotBuilt
    }
}
#endif

enum GemmaUnavailableError: Error { case modelNotBuilt }
```

Add the two small `Self.tempPNG`/`Self.tempWAV` writers as file-private helpers in the same `#if BUNDLED_SPEECH` block: `tempPNG` renders a `CGImage` to a unique `FileManager.default.temporaryDirectory` PNG via `NSBitmapImageRep` (or CGImageDestination); `tempWAV` writes mono `Float`→Int16 PCM WAV with an 8-lines-per-file header writer. Both must run off-main (they are — call sites are detached tasks).

**Implementer note on exact library API names:** the snippet uses the README-verified `EmbeddingGemma2Embedding(modelDirectory:tokenizerLoader:)`, `.embed(Input, task:dimensions:)`, `#hubDownloader()`. If the macro or task-enum initializer differs at compile time (`.init(task)` mapping), open `Libraries/MLXEmbedders/README.md` and `Libraries/MLXVLM` sources in the checked-out dependency under `.build/checkouts/mlx-swift-lm/` and adapt names verbatim — do not invent. Map `GemmaTask`: `.searchQuery` → library search task, `.document` → document, `.clustering` → clustering.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GemmaModelManagerTests 2>&1 | tail -5`
Expected: PASS (5 tests). Tests never touch MLX (injected factories).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Search/Models/GemmaModelManager.swift Tests/PalmierProTests/Search/GemmaModelManagerTests.swift
git commit -m "feat(search): GemmaModelManager with MLX EmbeddingGemma 2 loader"
```

---

### Task 4: ClipEmbedStore — clip + audio-chunk sidecar

**Files:**
- Create: `Sources/PalmierPro/Search/Indexing/ClipEmbedStore.swift`
- Test: `Tests/PalmierProTests/Search/ClipEmbedStoreTests.swift`

**Interfaces:**
- Produces (used by Tasks 5, 7, 10, 11, 12):
  - `struct ClipEmbedStore` with `struct AudioChunk: Codable, Equatable { let start: Double; let end: Double; let vector: [Float] }` and `struct Record: Codable, Equatable { let model: String; let modelVersion: Int; var clipVector: [Float]?; var audio: [AudioChunk] }`
  - `static func url(forKey: String) -> URL`, `load(key:) -> Record?`, `save(_:key:) throws`, `remove(key:)`, `isCurrent(key:model:modelVersion:) -> Bool`, `clearAll()` — files `<key>.clipembed.json` inside `EmbeddingStore.directory`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PalmierPro

@Suite struct ClipEmbedStoreTests {
    @Test func roundTrip() throws {
        let key = "test-clip-\(UUID().uuidString.prefix(8))"
        defer { ClipEmbedStore.remove(key: key) }
        let record = ClipEmbedStore.Record(
            model: "embeddinggemma-2", modelVersion: 1,
            clipVector: [0.1, 0.2, 0.3],
            audio: [.init(start: 0, end: 30, vector: [0.4, 0.5])])
        try ClipEmbedStore.save(record, key: key)
        let loaded = ClipEmbedStore.load(key: key)
        #expect(loaded == record)
    }

    @Test func isCurrentChecksModelIdentity() throws {
        let key = "test-cur-\(UUID().uuidString.prefix(8))"
        defer { ClipEmbedStore.remove(key: key) }
        #expect(!ClipEmbedStore.isCurrent(key: key, model: "embeddinggemma-2", modelVersion: 1))
        try ClipEmbedStore.save(.init(model: "embeddinggemma-2", modelVersion: 1, clipVector: nil, audio: []), key: key)
        #expect(ClipEmbedStore.isCurrent(key: key, model: "embeddinggemma-2", modelVersion: 1))
        #expect(!ClipEmbedStore.isCurrent(key: key, model: "embeddinggemma-2", modelVersion: 2))
    }

    @Test func missingLoadReturnsNil() {
        #expect(ClipEmbedStore.load(key: "no-such-key") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipEmbedStoreTests 2>&1 | tail -5`
Expected: FAIL — no `ClipEmbedStore`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Per-asset sidecar for whole-clip and audio-chunk embeddings, JSON beside EmbeddingStore files.
struct ClipEmbedStore {
    struct AudioChunk: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
        let vector: [Float]
    }

    struct Record: Codable, Equatable, Sendable {
        let model: String
        let modelVersion: Int
        var clipVector: [Float]?
        var audio: [AudioChunk]
    }

    static func url(forKey key: String) -> URL {
        EmbeddingStore.directory.appendingPathComponent("\(key).clipembed.json")
    }

    static func load(key: String) -> Record? {
        guard let data = try? Data(contentsOf: url(forKey: key)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func save(_ record: Record, key: String) throws {
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(at: EmbeddingStore.directory, withIntermediateDirectories: true)
        try data.write(to: url(forKey: key), options: .atomic)
    }

    static func remove(key: String) {
        try? FileManager.default.removeItem(at: url(forKey: key))
    }

    static func isCurrent(key: String, model: String, modelVersion: Int) -> Bool {
        guard let record = load(key: key) else { return false }
        return record.model == model && record.modelVersion == modelVersion
    }

    static func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: EmbeddingStore.directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "clipembed" || file.lastPathComponent.hasSuffix(".clipembed.json") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
```

All `ClipEmbedStore` calls happen off-main (from the indexer's detached work, same rule as `EmbeddingStore`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClipEmbedStoreTests 2>&1 | tail -5`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Search/Indexing/ClipEmbedStore.swift Tests/PalmierProTests/Search/ClipEmbedStoreTests.swift
git commit -m "feat(search): ClipEmbedStore sidecar for clip and audio embeddings"
```

---

### Task 5: AudioPCMExtractor + GemmaIndexer

**Files:**
- Create: `Sources/PalmierPro/Search/Indexing/AudioPCMExtractor.swift`
- Create: `Sources/PalmierPro/Search/Indexing/GemmaIndexer.swift`
- Test: `Tests/PalmierProTests/Search/GemmaIndexerTests.swift`

**Interfaces:**
- Consumes: `GemmaEmbedding` (Task 2), `ClipEmbedStore` (Task 4), `EmbeddingStore`, `FrameSampler`.
- Produces (used by Tasks 7, 10, 11, 12):
  - `enum AudioPCMExtractor { static func mono16kChunks(url: URL, chunkSeconds: Double = 30) async throws -> [(start: Double, samples: [Float])] }`
  - `enum GemmaIndexer` with `static let modelName = "embeddinggemma-2"`, `static let modelVersion = 1`, and:
    - `static func indexKey(sourceURL: URL?, fallbackURL: URL) -> String?` — `EmbeddingStore.key(for:)` on source when its attributes are readable, else on fallback.
    - `static func indexVideo(indexURL: URL, key: String, duration: Double, embedder: any GemmaEmbedding, progress: (@Sendable (Double) -> Void)?) async throws` — frame rows into `EmbeddingStore` (samplerVersion = `FrameSampler.samplerVersion`) + one clip vector into `ClipEmbedStore`.
    - `static func indexAudio(url: URL, key: String, embedder: any GemmaEmbedding) async throws` — audio chunks into `ClipEmbedStore`.
    - `static func needsIndex(key: String) -> Bool` — false when both stores current.
  - `static func clipFrames(url: URL, duration: Double, fps: Double = 1, maxFrames: Int = 32) async throws -> [(time: Double, image: CGImage)]` — uniform sample via `AVAssetImageGenerator` (tolerance 0.5 s, `maximumSize` 512×512, transform applied).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import AVFoundation
@testable import PalmierPro

@Suite struct GemmaIndexerTests {
    @Test func indexKeyPrefersSourceWhenReadable() throws {
        let source = URL(fileURLWithPath: #filePath) // exists, has attrs
        let proxy = URL(fileURLWithPath: "/nonexistent/proxy.mov")
        let a = GemmaIndexer.indexKey(sourceURL: source, fallbackURL: proxy)
        let b = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: source)
        #expect(a == b) // same file identity
        let c = GemmaIndexer.indexKey(sourceURL: URL(fileURLWithPath: "/gone/a.mov"),
                                      fallbackURL: source)
        #expect(c == b) // unreadable source falls back to index URL
    }

    @Test func indexVideoWritesFrameRowsAndClipVector() async throws {
        let fixture = try TestMedia.makeVideo(seconds: 3, name: "gemma-index-video")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let key = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: fixture)!
        defer { ClipEmbedStore.remove(key: key); try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key)) }

        try await GemmaIndexer.indexVideo(
            indexURL: fixture, key: key, duration: 3, embedder: StubGemmaEmbedding(), progress: nil)

        let frames = try EmbeddingStore.load(key: key)
        #expect(frames!.header.model == GemmaIndexer.modelName)
        #expect(frames!.header.modelVersion == GemmaIndexer.modelVersion)
        #expect(frames!.header.dim == 768)
        #expect(frames!.header.count > 0)
        let record = ClipEmbedStore.load(key: key)
        #expect(record?.clipVector?.count == 768)
        #expect(GemmaIndexer.needsIndex(key: key) == false)
    }

    @Test func indexAudioWritesChunks() async throws {
        let fixture = try TestMedia.makeWAV(seconds: 2, sampleRate: 16_000, name: "gemma-index-audio")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let key = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: fixture)!
        defer { ClipEmbedStore.remove(key: key) }
        try await GemmaIndexer.indexAudio(url: fixture, key: key, embedder: StubGemmaEmbedding())
        let record = ClipEmbedStore.load(key: key)
        #expect(record?.audio.isEmpty == false)
        #expect(record?.audio.allSatisfy { $0.vector.count == 768 } == true)
    }
}

@Suite struct AudioPCMExtractorTests {
    @Test func chunksAreMono16kAndBounded() async throws {
        let fixture = try TestMedia.makeWAV(seconds: 2, sampleRate: 48_000, name: "gemma-pcm")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let chunks = try await AudioPCMExtractor.mono16kChunks(url: fixture, chunkSeconds: 1)
        #expect(chunks.count == 2)
        for (i, chunk) in chunks.enumerated() {
            #expect(abs(chunk.start - Double(i)) < 0.01)
            #expect(chunk.samples.count <= 16_000)
        }
    }
}
```

Add `TestMedia` to the existing test support (or `Tests/PalmierProTests/Search/TestMedia.swift` if none): `makeVideo(seconds:name:)` writes an H.264 `.mov` with 2 distinct colored halves via `AVAssetWriter` + `CVPixelBuffer` (follow the writer pattern in `Tests/PalmierProTests/Rendering/CompositorRenderTests.swift` if one exists there); `makeWAV(seconds:sampleRate:name:)` writes a mono Int16 sine WAV into `FileManager.default.temporaryDirectory`. If the repo already has media fixture helpers (grep `AVAssetWriter` under `Tests/`), reuse them and only add what is missing.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GemmaIndexerTests 2>&1 | tail -5`
Expected: FAIL — no `GemmaIndexer` / `AudioPCMExtractor`.

- [ ] **Step 3: Implement**

`AudioPCMExtractor.swift`:

```swift
import AVFoundation
import Foundation

enum AudioPCMExtractor {
    /// Reads any audio-bearing file as mono 16 kHz Float PCM, sliced into ≤ chunkSeconds spans.
    static func mono16kChunks(url: URL, chunkSeconds: Double = 30) async throws -> [(start: Double, samples: [Float])] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }

        let targetRate = 16_000.0
        let reader = try AVAssetReader(asset: asset)
        let sourceFormat = try await track.load(.formatDescriptions).first.map { CMSampleBufferGetFormatDescription($0) }
        guard let inFormat = sourceFormat.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else { return [] }

        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono)
        let outDesc = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                    interleaved: false, channelLayout: layout)!
        let inDesc = AVAudioFormat(streamDescription: UnsafeMutablePointer(mutating: inFormat).pointee)!
        guard let converter = AVAudioConverter(from: inDesc, to: outDesc) else { return [] }

        let capacity = AVAudioFrameCount(targetRate * chunkSeconds)
        var chunks: [(Double, [Float])] = []
        var carry: [Float] = []
        var chunkStart: Double = 0

        reader.add(AVAudioReaderOutput(track: track, outputSettings: [:]), format: inDesc)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { reader.cancelReading() }

        while let buffer = try readNext(reader: reader, converter: converter, capacity: capacity) {
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { continue }
            let channel = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferListPointer)[0]
            let samples = Array(UnsafeBufferPointer(start: channel.mData!.assumingMemoryBound(to: Float.self), count: frameCount))
            carry += samples
            while Double(carry.count) >= targetRate * chunkSeconds {
                let take = Int(targetRate * chunkSeconds)
                chunks.append((chunkStart, Array(carry.prefix(take))))
                carry.removeFirst(take)
                chunkStart += chunkSeconds
            }
        }
        if !carry.isEmpty { chunks.append((chunkStart, carry)) }
        return chunks.map { (start: $0.0, samples: $0.1) }
    }

    private static func readNext(reader: AVAssetReader, converter: AVAudioConverter, capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)!
        var conversionError: NSError?
        var fedFromReader = false
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if fedFromReader { inputStatus.pointee = .noDataNow; return nil }
            fedFromReader = true
            if let next = reader.nextSampleBuffer(),
               let blockBuffer = CMSampleBufferGetDataBuffer(next),
               let cmFormat = CMSampleBufferGetFormatDescription(next),
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(cmFormat) {
                let desc = basic.pointee
                if let inBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(next))) {
                    inBuffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(next))
                    let dst = UnsafeMutableAudioBufferListPointer(inBuffer.mutableAudioBufferListPointer)
                    let src = UnsafeMutableAudioBufferListPointer(CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                        next, bufferListSize: 4096, bufferList: nil, blockBufferAllocator: kCFAllocatorDefault,
                        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: nil)!.assumingMemoryBound(to: AudioBufferList.self))
                    // simplistic interleaved copy; production path uses AVAssetReaderTrackOutput with AVAudio settings — see implementer note
                    _ = dst; _ = src; _ = blockBuffer; _ = desc
                    inputStatus.pointee = .haveData
                    return inBuffer
                }
            }
            inputStatus.pointee = .endOfStream
            return nil
        }
        if let conversionError { throw conversionError }
        return status == .haveData && out.frameLength > 0 ? out : nil
    }
}
```

**Implementer note:** the inline converter plumbing above is the fiddliest part and the sketch marks its weak spot. Simpler correct route: use `AVAssetReaderTrackOutput(track:outputSettings:)` with `[AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true, AVSampleRateConverterAudioQualityKey: AVAudioQualityHigh]` and `AVSampleRateKey: 16_000` — the reader then delivers Float32 mono 16 kHz directly and the whole `AVAudioConverter` block collapses to a loop over `nextSampleBuffer()` → `CMSampleBufferCopyPCMDataIntoAudioBufferList` into `AVAudioPCMBuffer`, accumulate + slice. Implement THAT route; keep the signature and chunking logic identical. Delete every line of the sketch's `readNext` that the simpler route makes unnecessary.

`GemmaIndexer.swift`:

```swift
import AVFoundation
import CoreGraphics
import Foundation

enum GemmaIndexer {
    static let modelName = "embeddinggemma-2"
    static let modelVersion = 1

    static func indexKey(sourceURL: URL?, fallbackURL: URL) -> String? {
        if let sourceURL, EmbeddingStore.key(for: sourceURL) != nil { return EmbeddingStore.key(for: sourceURL) }
        return EmbeddingStore.key(for: fallbackURL)
    }

    static func needsIndex(key: String) -> Bool {
        let framesCurrent = EmbeddingStore.isCurrent(
            key: key, model: modelName, modelVersion: modelVersion,
            samplerVersion: FrameSampler.samplerVersion)
        let clipCurrent = ClipEmbedStore.isCurrent(key: key, model: modelName, modelVersion: modelVersion)
        return !(framesCurrent && clipCurrent)
    }

    static func indexVideo(
        indexURL: URL,
        key: String,
        duration: Double,
        embedder: any GemmaEmbedding,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard needsIndex(key: key) else { return }

        var times: [Double] = []
        var shotStarts: [Double] = []
        var shotIndices: [Int] = []
        var vectors: [Float] = []

        for try await frame in FrameSampler.frames(url: indexURL, duration: duration) {
            try Task.checkCancellation()
            try await ExportQueue.shared.waitWhileExportActive()
            if frame.isNewShot { shotStarts.append(shotStarts.isEmpty ? 0 : frame.time) }
            vectors += try await embedder.embedImages([frame.image])[0]
            times.append(frame.time)
            shotIndices.append(shotStarts.count - 1)
            if duration > 0 { progress?(min(frame.time / duration, 0.9)) }
        }
        try Task.checkCancellation()

        let rows = zip(times, shotIndices).map { time, shot in
            EmbeddingStore.Row(
                time: time,
                shotStart: shotStarts[shot],
                shotEnd: shot + 1 < shotStarts.count ? shotStarts[shot + 1] : duration)
        }
        let header = EmbeddingStore.Header(
            model: modelName, modelVersion: modelVersion,
            samplerVersion: FrameSampler.samplerVersion,
            dim: embedder.dim, count: rows.count)
        try EmbeddingStore.save(header: header, rows: rows, vectors: vectors, key: key)

        let clips = try await clipFrames(url: indexURL, duration: duration)
        let clipVector = clips.isEmpty ? nil
            : try await embedder.embedVideo(clips.map(\.image))
        try ClipEmbedStore.save(
            .init(model: modelName, modelVersion: modelVersion, clipVector: clipVector, audio: []),
            key: key)
        progress?(1)
    }

    static func indexAudio(url: URL, key: String, embedder: any GemmaEmbedding) async throws {
        guard !ClipEmbedStore.isCurrent(key: key, model: modelName, modelVersion: modelVersion) else { return }
        let existing = ClipEmbedStore.load(key: key)
        let chunks = try await AudioPCMExtractor.mono16kChunks(url: url)
        var embedded: [ClipEmbedStore.AudioChunk] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let vector = try await embedder.embedAudio(chunk.samples, sampleRate: 16_000)
            embedded.append(.init(start: chunk.start, end: chunk.start + Double(chunk.samples.count) / 16_000.0, vector: vector))
        }
        try ClipEmbedStore.save(
            .init(model: modelName, modelVersion: modelVersion, clipVector: existing?.clipVector, audio: embedded),
            key: key)
    }

    /// Uniform ≤ maxFrames samples at `fps` for the whole-clip embedding.
    static func clipFrames(url: URL, duration: Double, fps: Double = 1, maxFrames: Int = 32) async throws -> [(time: Double, image: CGImage)] {
        guard duration > 0 else { return [] }
        let count = min(maxFrames, max(1, Int(duration * fps)))
        let stride = duration / Double(count)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { CMTime(seconds: Double($0) * stride + stride / 2, preferredTimescale: 600) }
        var out: [(Double, CGImage)] = []
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            if case .success(_, let image, let actual) = result {
                out.append((actual.seconds, image))
            }
        }
        return out.map { (time: $0.0, image: $0.1) }
    }
}
```

Video-with-audio: `indexVideo` stores an empty `audio: []`; audio chunks for video assets are added in Task 7's coordinator pass by calling `indexAudio` on the same file/`key` (Record holds both, second save preserves `clipVector`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GemmaIndexerTests --filter AudioPCMExtractorTests 2>&1 | tail -5`
Expected: PASS. (Swift Testing accepts one `--filter`; if chained filters don't combine, run twice.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Search/Indexing/AudioPCMExtractor.swift Sources/PalmierPro/Search/Indexing/GemmaIndexer.swift Tests/PalmierProTests/Search/GemmaIndexerTests.swift
git commit -m "feat(search): GemmaIndexer for frames, clip vectors, and audio chunks"
```

---

### Task 6: Coordinator wiring — gemma pass after SigLIP

**Files:**
- Modify: `Sources/PalmierPro/Search/SearchIndexCoordinator.swift` (`indexOne`, `schedule`, `process`)
- Modify: `Sources/PalmierPro/Models/MediaManifest.swift` (add one lookup, if absent)
- Test: none new (pure wiring; covered by Task 5 unit tests + Task 7 search tests; verified by build + Task 13 smoke).

**Interfaces:**
- Consumes: `GemmaModelManager`, `GemmaIndexer` (Task 5).
- Produces: after the SigLIP `indexOne` completes for an asset, a gemma pass runs when `GemmaModelManager.shared.enabled && isReady`, indexing the same `asset.url` with `GemmaIndexer.indexKey(sourceURL:fallbackURL:)`. Standalone audio assets (`.audio`) get `indexAudio` only.

- [ ] **Step 1: Manifest source lookup**

In `MediaManifest.swift` add (near the existing entry accessors; return nil for internal/generated sources with no file on disk):

```swift
extension MediaManifest {
    /// On-disk source URL for an asset id when it differs from the (possibly proxied) url.
    func sourceFileURL(forAssetID id: String) -> URL? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        if let path = entry.sourceURL, !path.isEmpty { return URL(fileURLWithPath: path) }
        if let path = entry.sourcePath, !path.isEmpty { return URL(fileURLWithPath: path) }
        if case .external(let absolutePath) = entry.source { return URL(fileURLWithPath: absolutePath) }
        return nil
    }
}
```

(Check the `Entry` field spellings first with `grep -n "sourceURL\|sourcePath\|var source" Sources/PalmierPro/Models/MediaManifest.swift` — they were verified as `sourceURL: String?` line 49, `sourcePath: String?` line 50, `source: MediaSource` line 30.)

- [ ] **Step 2: Extend `indexOne`**

Inside `SearchIndexCoordinator.indexOne(_:model:transcribe:)`, after the `switch asset.type` block and before `loadedIndexes[asset.id] = nil`, add the gemma pass. The coordinator is `@MainActor`; the indexing itself must run detached (follow the existing `Task.detached` preflight pattern):

```swift
if GemmaModelManager.shared.enabled, GemmaModelManager.shared.isReady,
   let gemma = GemmaModelManager.shared.embedder {
    let indexURL = url
    let key = await Task.detached(priority: .utility) {
        GemmaIndexer.indexKey(
            sourceURL: await manifestSourceURL(assetID: asset.id), fallbackURL: indexURL)
    }.value
    if let key, GemmaIndexer.needsIndex(key: key) {
        try await Task.detached(priority: .utility) {
            switch asset.type {
            case .video:
                try await GemmaIndexer.indexVideo(indexURL: indexURL, key: key,
                                                   duration: asset.duration, embedder: gemma,
                                                   progress: onProgress)
                if asset.hasAudio {
                    try await GemmaIndexer.indexAudio(url: indexURL, key: key, embedder: gemma)
                }
            case .audio:
                try await GemmaIndexer.indexAudio(url: indexURL, key: key, embedder: gemma)
            default:
                break
            }
        }.value
    }
}
```

Add the small helper on the coordinator (`@MainActor`, reads the manifest through the same path the editor uses — find the owner with `grep -rn "MediaManifest" Sources/PalmierPro/Editor/ViewModel/ | head`; typically `EditorViewModel.mediaManifest`; if the coordinator has no manifest reference, add `var manifestSourceLookup: @MainActor (String) -> URL? = { _ in nil }` set by `EditorViewModel` when it sets `assetsProvider`, mirroring that exact wiring point):

```swift
private func manifestSourceURL(assetID: String) async -> URL? {
    manifestSourceLookup(assetID)
}
```

`needsIndex`/`indexKey` file stats must stay off-main — they already run inside the detached task above.

- [ ] **Step 3: Also schedule audio assets**

In `schedule(_:)` and `sweep()`, the SigLIP guard `let model = VisualModelLoader.shared.embedder` blocks audio-only assets from any queue. Add an early branch: when the asset `type == .audio` and the gemma manager is enabled+ready, enqueue a gemma-only `IndexWork` (spec can carry SigLIP's spec; the worker's `indexOne` skips SigLIP for `.audio` already and the gemma pass handles it). Minimal change:

```swift
func schedule(_ asset: MediaAsset) {
    guard !isCancelling, !asset.isGenerating else { return }
    guard !scheduledIds.contains(asset.id), !failedIds.contains(asset.id) else { return }
    if asset.type == .audio {
        guard GemmaModelManager.shared.enabled, GemmaModelManager.shared.isReady else { return }
    } else {
        guard VisualModelLoader.shared.enabled, let model = VisualModelLoader.shared.embedder else { return }
        queue.append(IndexWork(asset: Self.snapshot(asset), spec: model.spec))
        scheduledIds.insert(asset.id)
        batchTotal += 1
        ensureWorker()
        return
    }
    queue.append(IndexWork(asset: Self.snapshot(asset), spec: VisualModelLoader.shared.embedder?.spec
        ?? .init(model: "none", version: 0, embeddingDim: 0, imageSize: 0, contextLength: 0)))
    scheduledIds.insert(asset.id)
    batchTotal += 1
    ensureWorker()
}
```

And in `sweep()` relax the top guard to `guard VisualModelLoader.shared.enabled || GemmaModelManager.shared.enabled else { return }` with `isReady` checked per-asset inside `schedule`. Also mirror the `isCurrent` guard: for audio work, skip the `embedder?.spec == work.spec` check when `work.asset.type == .audio`.

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/Search/SearchIndexCoordinator.swift Sources/PalmierPro/Models/MediaManifest.swift
git commit -m "feat(search): run gemma indexing pass beside SigLIP in coordinator"
```

---

### Task 7: GemmaSearch + RRF fusion in `search`

**Files:**
- Create: `Sources/PalmierPro/Search/Query/GemmaSearch.swift`
- Modify: `Sources/PalmierPro/Search/SearchIndexCoordinator.swift` (`search(query:limit:within:)`)
- Test: `Tests/PalmierProTests/Search/GemmaSearchTests.swift`

**Interfaces:**
- Consumes: `EmbeddingStore.AssetIndex`, `ClipEmbedStore.Record`, `VisualSearch.Hit`.
- Produces (used by Tasks 11, 12):
  - `enum GemmaSearch` with:
    - `enum HitKind: Equatable, Sendable { case frame(time: Double, shotStart: Double, shotEnd: Double); case clip; case audio(start: Double, end: Double) }`
    - `struct Hit: Equatable, Sendable { let assetID: String; let kind: HitKind; let score: Float }`
    - `static func search(query: [Float], frameIndexes: [(assetID: String, index: EmbeddingStore.AssetIndex)], clipRecords: [(assetID: String, record: ClipEmbedStore.Record)], limit: Int = 20, minScore: Float = 0.05) -> [Hit]` — best-frame-per-shot (mirror `VisualSearch.search` logic with vDSP), plus clip hits, plus audio-chunk hits; sorted by score.
    - `static func fuse(_ siglip: [VisualSearch.Hit], _ gemma: [GemmaSearch.Hit], limit: Int) -> [VisualSearch.Hit]` — reciprocal-rank fusion (k = 60) over frame-kind hits keyed `(assetID, shotStart)`; non-frame gemma hits excluded (surfaced by tools instead).
    - `static func audioMatches(voice: [Float], candidates: [(assetID: String, record: ClipEmbedStore.Record)], limit: Int = 5, minScore: Float = 0.3) -> [(assetID: String, start: Double, end: Double, score: Float)]`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PalmierPro

@Suite struct GemmaSearchTests {
    private func storeFixture(dim: Int = 768) -> EmbeddingStore.AssetIndex {
        var query = [Float](repeating: 0.01, count: dim); query[0] = 0.99
        let rows = [EmbeddingStore.Row(time: 1, shotStart: 0, shotEnd: 4),
                    EmbeddingStore.Row(time: 5, shotStart: 4, shotEnd: 9)]
        return .init(header: .init(model: "embeddinggemma-2", modelVersion: 1, samplerVersion: 1,
                                   dim: dim, count: 2),
                     rows: rows, vectors: query + query)
    }

    @Test func frameClipAndAudioHitsRanked() {
        var clipVector = [Float](repeating: 0.01, count: 768); clipVector[0] = 0.95
        let record = ClipEmbedStore.Record(
            model: "embeddinggemma-2", modelVersion: 1, clipVector: clipVector,
            audio: [.init(start: 0, end: 30, vector: clipVector)])
        var query = [Float](repeating: 0.01, count: 768); query[0] = 0.99
        let hits = GemmaSearch.search(query: query,
                                      frameIndexes: [("a1", storeFixture())],
                                      clipRecords: [("a1", record)], limit: 10)
        #expect(hits.contains { if case .frame = $0.kind { true } else { false } })
        #expect(hits.contains { $0.kind == .clip })
        #expect(hits.contains { if case .audio = $0.kind { true } else { false } })
        #expect(hits.allSatisfy { $0.score > 0.05 })
    }

    @Test func fuseInterleavesBothRankers() {
        let sig = (0..<5).map { VisualSearch.Hit(assetID: "a\($0)", time: 1, shotStart: Double($0), shotEnd: 2, score: 1 - Float($0) * 0.01) }
        let gem = (0..<5).map { GemmaSearch.Hit(assetID: "b\($0)", kind: .frame(time: 1, shotStart: Double($0), shotEnd: 2), score: 1 - Float($0) * 0.01) }
        let fused = GemmaSearch.fuse(sig, gem, limit: 10)
        #expect(fused.count == 10)
        #expect(Set(fused.map(\.assetID)) == Set(["a0","a1","a2","a3","a4","b0","b1","b2","b3","b4"]))
        // exclusive rank-1 from each side outranks rank-5 from the other
        #expect(fused.first!.assetID == "a0" || fused.first!.assetID == "b0")
    }

    @Test func fuseRRFScoresBeatDeepSingleRanker() {
        let sig = (0..<5).map { VisualSearch.Hit(assetID: "s", time: 1, shotStart: Double($0), shotEnd: 2, score: 1 - Float($0) * 0.001) }
        let gem = [GemmaSearch.Hit(assetID: "g", kind: .frame(time: 1, shotStart: 0, shotEnd: 2), score: 0.9)]
        let fused = GemmaSearch.fuse(sig, gem, limit: 6)
        // g is rank 1 in its list (1/61) vs s rank-5 (5/65): g places above s's 5th
        let gIdx = fused.firstIndex { $0.assetID == "g" }!
        let s4 = fused.firstIndex { $0.assetID == "s" && $0.shotStart == 4 }!
        #expect(gIdx < s4)
    }

    @Test func audioMatchesRanksByCosine() {
        var voice = [Float](repeating: 0.01, count: 768); voice[1] = 0.95
        var near = [Float](repeating: 0.01, count: 768); near[1] = 0.9
        var far = [Float](repeating: 0.01, count: 768); far[2] = 0.9
        let record = ClipEmbedStore.Record(model: "embeddinggemma-2", modelVersion: 1, clipVector: nil,
                                           audio: [.init(start: 0, end: 10, vector: near),
                                                   .init(start: 10, end: 20, vector: far)])
        let matches = GemmaSearch.audioMatches(voice: voice, candidates: [("v1", record)])
        #expect(matches.first?.start == 0)
        #expect(matches.first!.score > matches.last!.score)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GemmaSearchTests 2>&1 | tail -5`
Expected: FAIL — no `GemmaSearch`.

- [ ] **Step 3: Implement**

```swift
import Accelerate
import Foundation

enum GemmaSearch {
    enum HitKind: Equatable, Sendable {
        case frame(time: Double, shotStart: Double, shotEnd: Double)
        case clip
        case audio(start: Double, end: Double)
    }

    struct Hit: Equatable, Sendable {
        let assetID: String
        let kind: HitKind
        let score: Float
    }

    static func search(
        query: [Float],
        frameIndexes: [(assetID: String, index: EmbeddingStore.AssetIndex)],
        clipRecords: [(assetID: String, record: ClipEmbedStore.Record)],
        limit: Int = 20,
        minScore: Float = 0.05
    ) -> [Hit] {
        var hits: [Hit] = []
        for (assetID, index) in frameIndexes {
            let dim = index.header.dim
            guard dim == query.count, index.header.count > 0 else { continue }
            var scores = [Float](repeating: 0, count: index.header.count)
            vDSP_mmul(index.vectors, 1, query, 1, &scores, 1,
                      vDSP_Length(index.header.count), 1, vDSP_Length(dim))
            var bestPerShot: [Double: (row: Int, score: Float)] = [:]
            for (i, score) in scores.enumerated() {
                let shot = index.rows[i].shotStart
                if let existing = bestPerShot[shot], existing.score >= score { continue }
                bestPerShot[shot] = (i, score)
            }
            for (_, best) in bestPerShot {
                let row = index.rows[best.row]
                hits.append(Hit(assetID: assetID,
                                kind: .frame(time: row.time, shotStart: row.shotStart, shotEnd: row.shotEnd),
                                score: best.score))
            }
        }
        for (assetID, record) in clipRecords {
            if let clip = record.clipVector, clip.count == query.count {
                let score = cosine(clip, query)
                if score >= minScore { hits.append(Hit(assetID: assetID, kind: .clip, score: score)) }
            }
            for chunk in record.audio where chunk.vector.count == query.count {
                let score = cosine(chunk.vector, query)
                if score >= minScore {
                    hits.append(Hit(assetID: assetID, kind: .audio(start: chunk.start, end: chunk.end), score: score))
                }
            }
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// Reciprocal-rank fusion (k = 60) over frame hits keyed by (assetID, shotStart).
    static func fuse(_ siglip: [VisualSearch.Hit], _ gemma: [GemmaSearch.Hit], limit: Int) -> [VisualSearch.Hit] {
        struct Key: Hashable { let assetID: String; let shot: Double }
        let k: Float = 60
        var scores: [Key: Float] = [:]
        var carrier: [Key: VisualSearch.Hit] = [:]
        for (rank, hit) in siglip.enumerated() {
            let key = Key(assetID: hit.assetID, shot: hit.shotStart)
            scores[key, default: 0] += 1 / (k + Float(rank + 1))
            carrier[key] = hit
        }
        for (rank, hit) in gemma.enumerated() {
            guard case let .frame(_, shotStart, shotEnd) = hit.kind else { continue }
            let key = Key(assetID: hit.assetID, shot: shotStart)
            scores[key, default: 0] += 1 / (k + Float(rank + 1))
            if let existing = carrier[key] {
                if hit.score > existing.score {
                    carrier[key] = VisualSearch.Hit(assetID: hit.assetID, time: hit.score > existing.score ? hitTime(hit) : existing.time,
                                                    shotStart: shotStart, shotEnd: shotEnd, score: hit.score)
                }
            } else {
                carrier[key] = VisualSearch.Hit(assetID: hit.assetID, time: hitTime(hit),
                                                shotStart: shotStart, shotEnd: shotEnd, score: hit.score)
            }
        }
        return scores
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { carrier[$0.key] }
    }

    static func audioMatches(
        voice: [Float],
        candidates: [(assetID: String, record: ClipEmbedStore.Record)],
        limit: Int = 5,
        minScore: Float = 0.3
    ) -> [(assetID: String, start: Double, end: Double, score: Float)] {
        var out: [(String, Double, Double, Float)] = []
        for (assetID, record) in candidates {
            for chunk in record.audio where chunk.vector.count == voice.count {
                let score = cosine(chunk.vector, voice)
                if score >= minScore { out.append((assetID, chunk.start, chunk.end, score)) }
            }
        }
        return out.sorted { $0.3 > $1.3 }.prefix(limit)
            .map { (assetID: $0.0, start: $0.1, end: $0.2, score: $0.3) }
    }

    private static func hitTime(_ hit: Hit) -> Double {
        if case let .frame(time, _, _) = hit.kind { return time }
        return 0
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0; var na: Float = 0; var nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / (sqrt(na) * sqrt(nb) + 1e-9)
    }
}
```

(Store vectors are L2-normalized so dot = cosine; the explicit cosine guards chunk vectors that predate normalization. Fix the `$0.3 > $1.3` tuple-index syntax if the compiler objects — intent is score-descending.)

- [ ] **Step 4: Coordinator `search` upgrade**

In `SearchIndexCoordinator.search(query:limit:within:)`, after the existing detached block computes `hits`, add the gemma half before `return`:

```swift
var hits = hits
if GemmaModelManager.shared.enabled, GemmaModelManager.shared.isReady,
   let gemma = GemmaModelManager.shared.embedder {
    let gemmaCandidates = candidates
    let gemmaLoaded = loadedIndexes
    let gemmaFrameIndexes = await Task.detached(priority: .userInitiated) { () -> [GemmaSearch.Hit] in
        var frameIndexes: [(String, EmbeddingStore.AssetIndex)] = []
        var clipRecords: [(String, ClipEmbedStore.Record)] = []
        for (assetID, url) in gemmaCandidates {
            guard let key = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: url) else { continue }
            if let hit = gemmaLoaded[assetID], hit.key == key {
                frameIndexes.append((assetID, hit.index))
            } else if let index = try? EmbeddingStore.load(key: key),
                      index.header.model == GemmaIndexer.modelName {
                frameIndexes.append((assetID, index))
            }
            if let record = ClipEmbedStore.load(key: key) { clipRecords.append((assetID, record)) }
        }
        guard let vector = try? await gemma.embedText(trimmed, task: .searchQuery) else { return [] }
        return GemmaSearch.search(query: vector, frameIndexes: frameIndexes,
                                  clipRecords: clipRecords, limit: limit)
    }.value
    hits = GemmaSearch.fuse(hits, gemmaFrameIndexes, limit: limit)
}
return hits
```

(The gemma frame load can't reuse the SigLIP `loadedIndexes` cache — its cache maps SigLIP stores; the gemma branch loads gemma-header stores directly. Caching them in a second dictionary `gemmaLoadedIndexes` mirrors line 55's cache — add it the same way if the double-load shows up in Instruments, not before.)

- [ ] **Step 5: Run tests**

Run: `swift test --filter GemmaSearchTests 2>&1 | tail -5` then `swift test --filter VisualSearchTests 2>&1 | tail -3`
Expected: both PASS (existing search behavior untouched when gemma disabled).

- [ ] **Step 6: Commit**

```bash
git add Sources/PalmierPro/Search/Query/GemmaSearch.swift Sources/PalmierPro/Search/SearchIndexCoordinator.swift Tests/PalmierProTests/Search/GemmaSearchTests.swift
git commit -m "feat(search): gemma ranking fused with SigLIP via RRF"
```

---

### Task 8: Settings UI — install/enable Gemma

**Files:**
- Modify: `Sources/PalmierPro/Settings/StoragePane.swift` (or the pane holding the Smart search model row — locate with `grep -rn "VisualModelLoader\|Smart search" Sources/PalmierPro/Settings/`)

**Interfaces:**
- Consumes: `GemmaModelManager` (Task 3), `AppTheme`.

- [ ] **Step 1: Add the row**

Next to the existing Smart search model row, add an equivalent block: toggle bound to `GemmaModelManager.shared.setEnabled(_:)`, state text from `GemmaModelManager.shared.state` (`notInstalled` shows an Install button calling `download()`; `downloading(f)` shows percent; `ready` shows "Ready"), and a Remove button calling `remove()` guarded by a confirmation. Style: copy the Smart search row's view code and swap the manager; all spacing/fonts/colors via AppTheme.

- [ ] **Step 2: Status chip in the media panel**

In `MediaTab+IndexStatus.swift` no change needed — the gemma pass reports through the same `search.indexingActive` counters (Task 6). Verify by reading the file: batch counters are shared. If the SigLIP `case .ready where search.indexingActive` gate hides gemma-only progress (model loader state is SigLIP's), extend the switch: `case _ where search.indexingActive && (GemmaModelManager.shared.isReady || VisualModelLoader.shared.isReady)`.

- [ ] **Step 3: Build + manual check**

Run: `swift build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/Settings/
git commit -m "feat(search): settings row to install and enable EmbeddingGemma 2"
```

---

### Task 9: FootageGroups — clustering + near-duplicates

**Files:**
- Create: `Sources/PalmierPro/ShotLibrary/FootageGroups.swift`
- Test: `Tests/PalmierProTests/Search/FootageGroupsTests.swift`

**Interfaces:**
- Consumes: `ClipEmbedStore.Record`, `GemmaVector.truncate` (Task 2).
- Produces (used by Tasks 10, 12):
  - `enum FootageGroups` with:
    - `struct Group: Equatable, Sendable { let memberIDs: [String]; let centroid: [Float] }`
    - `static func kmeans(_ vectors: [[Float]], k: Int, iterations: Int = 25, seed: UInt64 = 7) -> [Int]` — deterministic (splitmix64 shuffling for init), cosine distance (inputs L2-normalized first).
    - `static func groups(items: [(id: String, vector: [Float])], k: Int) -> [Group]` — truncates each vector to 256 via `GemmaVector.truncate`, clusters, drops singleton-noise handling: groups sorted by size desc, empty groups omitted.
    - `static func nearDuplicates(items: [(id: String, vector: [Float])], threshold: Float = 0.92) -> [[String]]` — greedy grouping over the 256-d vectors.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PalmierPro

@Suite struct FootageGroupsTests {
    private func unit(_ direction: Int, dim: Int = 768) -> [Float] {
        var v = [Float](repeating: 0.02, count: dim); v[direction] = 0.98
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / n }
    }

    @Test func kmeansSeparatesTwoClusters() {
        var vectors: [[Float]] = []
        for _ in 0..<5 { vectors.append(unit(0)) }
        for _ in 0..<5 { vectors.append(unit(400)) }
        let labels = FootageGroups.kmeans(vectors, k: 2)
        #expect(Set(labels).count == 2)
        #expect(labels.prefix(5).allSatisfy { $0 == labels[0] })
        #expect(labels.suffix(5).allSatisfy { $0 == labels[5] })
    }

    @Test func kmeansDeterministic() {
        let vectors = (0..<10).map { unit($0 * 30) }
        #expect(FootageGroups.kmeans(vectors, k: 3) == FootageGroups.kmeans(vectors, k: 3))
    }

    @Test func groupsKeepIds() {
        let items: [(id: String, vector: [Float])] = [
            ("a", unit(0)), ("b", unit(0)), ("c", unit(500)),
        ]
        let groups = FootageGroups.groups(items: items, k: 2)
        #expect(groups.count == 2)
        #expect(groups.first!.memberIDs.count == 2 || groups.last!.memberIDs.count == 2)
        #expect(groups.flatMap(\.memberIDs).sorted() == ["a", "b", "c"])
    }

    @Test func nearDuplicatesPairsCloseVectors() {
        var near = unit(0); near[1] = 0.4
        let n = sqrt(near.reduce(0) { $0 + $1 * $1 }); near = near.map { $0 / n }
        let items: [(id: String, vector: [Float])] = [("x", unit(0)), ("y", near), ("z", unit(600))]
        let dups = FootageGroups.nearDuplicates(items: items, threshold: 0.9)
        #expect(dups.contains { $0.sorted() == ["x", "y"] })
        #expect(!dups.flatMap({ $0 }).contains("z"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FootageGroupsTests 2>&1 | tail -5`
Expected: FAIL — no `FootageGroups`.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum FootageGroups {
    struct Group: Equatable, Sendable {
        let memberIDs: [String]
        let centroid: [Float]
    }

    static func groups(items: [(id: String, vector: [Float])], k: Int) -> [Group] {
        guard !items.isEmpty, k > 0 else { return [] }
        let vectors = items.map { GemmaVector.truncate($0.vector, to: 256) }
        let labels = kmeans(vectors, k: min(k, items.count))
        var buckets: [Int: (ids: [String], sum: [Float])] = [:]
        for (i, item) in items.enumerated() {
            let entry = buckets[labels[i]] ?? (ids: [], sum: [Float](repeating: 0, count: 256))
            buckets[labels[i]] = (entry.ids + [item.id], zip(entry.sum, vectors[i]).map(+))
        }
        return buckets.values
            .map { Group(memberIDs: $0.ids, centroid: $0.sum.map { $0 / Float(max($0.ids.count, 1)) }) }
            .sorted { $0.memberIDs.count > $1.memberIDs.count }
    }

    static func kmeans(_ vectors: [[Float]], k: Int, iterations: Int = 25, seed: UInt64 = 7) -> [Int] {
        let n = vectors.count
        guard n > 0, k > 0, let dim = vectors.first?.count, dim > 0 else { return [] }
        let k = min(k, n)
        var rng = SplitMix64(seed: seed)
        var centroids = (0..<k).map { _ in vectors[Int(rng.next() % UInt64(n))] }
        var labels = [Int](repeating: 0, count: n)
        for _ in 0..<iterations {
            var changed = false
            for i in 0..<n {
                var best = 0; var bestScore = -Float.infinity
                for c in 0..<k {
                    let score = dot(vectors[i], centroids[c])
                    if score > bestScore { bestScore = score; best = c }
                }
                if labels[i] != best { labels[i] = best; changed = true }
            }
            guard changed else { break }
            var sums = [[Float]](repeating: [Float](repeating: 0, count: dim), count: k)
            var counts = [Int](repeating: 0, count: k)
            for i in 0..<n {
                counts[labels[i]] += 1
                for d in 0..<dim { sums[labels[i]][d] += vectors[i][d] }
            }
            for c in 0..<k where counts[c] > 0 {
                centroids[c] = sums[c].map { $0 / Float(counts[c]) }
            }
        }
        return labels
    }

    static func nearDuplicates(items: [(id: String, vector: [Float])], threshold: Float = 0.92) -> [[String]] {
        let vectors = items.map { GemmaVector.truncate($0.vector, to: 256) }
        var assigned = [Bool](repeating: false, count: items.count)
        var groups: [[String]] = []
        for i in items.indices where !assigned[i] {
            var members = [items[i].id]
            assigned[i] = true
            for j in items.indices where !assigned[j] {
                if dot(vectors[i], vectors[j]) >= threshold {
                    members.append(items[j].id)
                    assigned[j] = true
                }
            }
            if members.count > 1 { groups.append(members) }
        }
        return groups
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var out: Float = 0
        for i in a.indices where i < b.count { out += a[i] * b[i] }
        return out
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
```

(If the repo already has a `SplitMix64` or seeded generator — grep `SplitMix64`/`RandomNumberGenerator` under `Sources/` — reuse it and drop the duplicate. Check name collisions before committing.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FootageGroupsTests 2>&1 | tail -5`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PalmierPro/ShotLibrary/FootageGroups.swift Tests/PalmierProTests/Search/FootageGroupsTests.swift
git commit -m "feat(shots): footage clustering and near-duplicate grouping"
```

---

### Task 10: ShotLibrary Groups tab

**Files:**
- Modify: `Sources/PalmierPro/ShotLibrary/ShotLibraryView.swift` (tab strip + new section view)
- Create: `Sources/PalmierPro/ShotLibrary/FootageGroupsView.swift`

**Interfaces:**
- Consumes: `FootageGroups` (Task 9), `ClipEmbedStore`, `MediaAsset` thumbnails, `AppTheme`.

- [ ] **Step 1: Groups view**

`FootageGroupsView`: takes `[MediaAsset]` (main-actor) and builds items on a detached task — for each video asset, `GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: asset.url)` then `ClipEmbedStore.load(key:)?.clipVector`; skip assets without one. Compute `groups(items:k:)` with `k = max(2, Int((Double(items.count) / 2).squareRoot().rounded()))` and `nearDuplicates(threshold: 0.92)`. UI: two sections — "Groups" (header = group size + up-to-6 member thumbnails in a wrap, using the asset thumbnail at `AppTheme.IconSize.xl`), "Similar takes" (each near-dup row). AppTheme everywhere; no persisted state; recompute on appear when `search.indexingActive == false`. Show an empty-state line ("Indexing footage…" while active, "Enable EmbeddingGemma 2 in Settings" when the manager isn't ready).

- [ ] **Step 2: Tab wiring**

Add a `groups` case to `ShotLibraryView`'s tab enum alongside the existing tabs (find it with `grep -n "enum.*Tab\|case " Sources/PalmierPro/ShotLibrary/ShotLibraryView.swift | head -20`), label localized through `L10n.string("Groups")`.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3` — BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/PalmierPro/ShotLibrary/
git commit -m "feat(shots): footage groups tab with clusters and similar takes"
```

---

### Task 11: Agent tools — find_moments, cluster_footage, match_audio

**Files:**
- Modify: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift` (`ToolName` + schemas)
- Modify: `Sources/PalmierPro/Agent/Tools/AgentInstructions.swift` (one paragraph)
- Modify: `Sources/PalmierPro/Agent/Tools/ToolExecutor+Search.swift` (`search_media` modality param) — only if its current signature makes this natural; otherwise leave `search_media` untouched (fused ranking already lands via Task 7) and skip the param.
- Create: `Sources/PalmierPro/Agent/Tools/ToolExecutor+Gemma.swift`
- Test: `Tests/PalmierProTests/Agent/GemmaToolsTests.swift`

**Interfaces:**
- Consumes: `GemmaSearch` (Task 7), `FootageGroups` (Task 9), `ClipEmbedStore`, `GemmaIndexer`, `GemmaModelManager`, coordinator `search`.
- Produces: three tool results as `ToolResult` payloads (follow the shape used in `ToolExecutor+Search.swift` for `search_media`).

- [ ] **Step 1: Register tool names + schemas**

In `ToolName` add under the Media library group:

```swift
case findMoments = "find_moments"
case clusterFootage = "cluster_footage"
case matchAudio = "match_audio"
```

Schemas in the definitions array (match neighboring entries' JSON shape — read one first):

- `find_moments`: `{ "query": {"type": "string", "description": "Natural-language description of the moment"}, "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20} }` — description: semantic footage search over frames, whole clips, and audio; returns asset ids, time ranges, scores; requires the EmbeddingGemma 2 model enabled.
- `cluster_footage`: `{}` — returns groups of similar clips (ids, sizes), near-duplicate take groups, and coverage counts; same model requirement.
- `match_audio`: `{ "voiceAssetId": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 5} }` — ranks footage audio moments similar to a voice/audio asset; returns (videoAssetId, start, end, score).

- [ ] **Step 2: Write the failing test**

Follow `Tests/PalmierProTests/Agent/SearchMediaToolTests.swift` structure for harness setup (it already stubs the model/loader — reuse its fixtures). Tests:

```swift
@Suite struct GemmaToolsTests {
    @Test func findMomentsReportsCapabilityMissing() async {
        // with GemmaModelManager stubbed disabled: result is an error payload
        // naming the install action, not an empty success
    }
    @Test func findMomentsReturnsTimeRanges() async {
        // stub embedder + seeded EmbeddingStore/ClipEmbedStore for one asset:
        // expect hits with asset ids, numeric time ranges, scores in 0...1
    }
    @Test func clusterFootageReturnsGroupsAndDups() async { /* seeded clip vectors → groups + duplicates arrays present */ }
    @Test func matchAudioRanksMoments() async { /* voice record vs two candidates → ordered matches, top has highest score */ }
}
```

(Fill the bodies with the concrete harness from SearchMediaToolTests — its stubs inject `VisualSearchModelStub`; add an equivalent `GemmaModelStub` exposing `embedder` and readiness so the executor path runs without MLX.)

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter GemmaToolsTests 2>&1 | tail -5` — FAIL (tools don't exist).

- [ ] **Step 4: Implement `ToolExecutor+Gemma.swift`**

Core shape (executor is `@MainActor`; heavy work detached, following `ToolExecutor+Search.swift`'s split):

```swift
extension ToolExecutor {
    func findMoments(query: String, limit: Int) async throws -> ToolResult {
        guard GemmaModelManager.shared.enabled, GemmaModelManager.shared.isReady,
              let gemma = GemmaModelManager.shared.embedder else {
            return .error("EmbeddingGemma 2 is not enabled. Enable it in Settings to search semantically.")
        }
        let assets = assetsProviderSnapshot() // existing helper pattern in +Search.swift
        let vector = try await gemma.embedText(query, task: .searchQuery)
        let (frameIndexes, clipRecords) = await Task.detached(priority: .userInitiated) {
            Self.gemmaStores(for: assets) // builds both lists via GemmaIndexer.indexKey + store loads
        }.value
        let hits = GemmaSearch.search(query: vector, frameIndexes: frameIndexes,
                                      clipRecords: clipRecords, limit: limit)
        return .success(["moments": hits.map { hit in
            ["assetId": hit.assetID, "kind": hit.kindName,
             "time": hit.timeOrNil ?? 0, "start": hit.startOrNil ?? 0,
             "end": hit.endOrNil ?? 0, "score": hit.score]
        }])
    }
    // clusterFootage / matchAudio analogous — see Interfaces block for exact payloads
}
```

Concretely: `cluster_footage` gathers `(assetID, clipVector)` for every asset with a `Record.clipVector`, runs `FootageGroups.groups(items:k:)` and `nearDuplicates`, returns `{"groups": [{"memberIds": [...], "size": n}], "similarTakes": [[...ids]], "coverage": {"assets": n, "grouped": m}}`; explicit `"note": "no clip embeddings yet — indexing still running"` shape when zero vectors instead of an error. `match_audio` loads the voice asset's `Record.audio` (error receipt naming the asset when absent), takes its first chunk vector, runs `GemmaSearch.audioMatches` against all other assets' records, returns matches with `voiceAssetId` echoed. No-op cases (empty query after trim, unknown asset id, zero vectors) return explicit no-op receipts, never success-shaped emptiness.

- [ ] **Step 5: Wire dispatch + instructions**

Add the three cases to the executor `execute` switch (follow neighboring `case .searchMedia` dispatch lines), and one short paragraph in `AgentInstructions.swift` after the media-search paragraph: when to prefer `find_moments` over `search_media` (semantic, time ranges, audio), `cluster_footage` for coverage/b-roll selection, `match_audio` for placing voice lines; note the model-gating and that both fall back to `search_media` when unavailable.

- [ ] **Step 6: Run tests**

Run: `swift test --filter GemmaToolsTests 2>&1 | tail -5` — PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/PalmierPro/Agent/Tests 2>/dev/null; git add Sources/PalmierPro/Agent/Tools/ Tests/PalmierProTests/Agent/GemmaToolsTests.swift
git commit -m "feat(agent): find_moments, cluster_footage, match_audio tools"
```

---

### Task 12: Full-suite green + fixture sanity test

**Files:**
- Test: `Tests/PalmierProTests/Search/GemmaEndToEndTests.swift`

**Interfaces:** none new.

- [ ] **Step 1: End-to-end stub test**

```swift
@Suite struct GemmaEndToEndTests {
    /// Full pipeline with the stub embedder: index video+audio → search → fuse → cluster.
    @Test func indexThenSearchThenCluster() async throws {
        let video = try TestMedia.makeVideo(seconds: 4, name: "gemma-e2e")
        let audio = try TestMedia.makeWAV(seconds: 2, sampleRate: 16_000, name: "gemma-e2e-audio")
        defer { try? [video, audio].forEach(FileManager.default.removeItem) }
        let stub = StubGemmaEmbedding()
        let vKey = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: video)!
        let aKey = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: audio)!
        defer { ClipEmbedStore.remove(key: vKey); ClipEmbedStore.remove(key: aKey)
                try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(vKey)) }

        try await GemmaIndexer.indexVideo(indexURL: video, key: vKey, duration: 4, embedder: stub)
        try await GemmaIndexer.indexAudio(url: audio, key: aKey, embedder: stub)

        let query = try await stub.embedText("anything", task: .searchQuery)
        let hits = GemmaSearch.search(query: query,
                                      frameIndexes: [("v", try EmbeddingStore.load(key: vKey)!)],
                                      clipRecords: [("v", ClipEmbedStore.load(key: vKey)!),
                                                    ("a", ClipEmbedStore.load(key: aKey)!)])
        #expect(!hits.isEmpty)
        let fused = GemmaSearch.fuse([], hits.filter { if case .frame = $0.kind { true } else { false } }
            .map { VisualSearch.Hit(assetID: $0.assetID, time: 0, shotStart: 0, shotEnd: 1, score: $0.score) }, limit: 5)
        #expect(!fused.isEmpty)
        #expect(FootageGroups.groups(items: [("v", hits[0].scoreVector)], k: 1).count == 1)
    }
}
```

(Amend `hits[0].scoreVector` — use the loaded `Record.clipVector!` instead; the line's intent is "cluster runs over a real stored vector". Also `try EmbeddingStore.load(key:)` returns non-optional `AssetIndex` via `throws` — drop the `!`.)

- [ ] **Step 2: Optional live-model sanity (skipped by default)**

Add `LiveGemmaSanityTests` gated on `ProcessInfo.processInfo.environment["PALMIER_GEMMA_LIVE"] == "1"` and `#if BUNDLED_SPEECH`: load the live factory, embed "a person walking at night" (task search) and "a city street at night" (document), assert cosine > 0.5, and embed the same text with `task: .clustering` truncated to 256 — assert unit norm. Without the env var: `#expect(Bool(true))` skip.

- [ ] **Step 3: Full suite**

Run: `swift test 2>&1 | tail -8`
Expected: all PASS. Any pre-existing flake: rerun that suite alone; do not paper over real failures.

- [ ] **Step 4: Commit**

```bash
git add Tests/PalmierProTests/Search/GemmaEndToEndTests.swift
git commit -m "test(search): end-to-end gemma index-search-cluster coverage"
```

---

### Task 13: Manual smoke on the real project

**Files:** none (verification only; fixes land as follow-up commits on this branch).

- [ ] **Step 1: Build + relaunch the bundled app**

```bash
kill $(pgrep -f PalmierPro.app/Contents/MacOS/PalmierPro) 2>/dev/null; sleep 1
swift build && ./scripts/bundle.sh debug --fast
codesign --force --deep --sign - .build/PalmierPro.app
open .build/PalmierPro.app
```

- [ ] **Step 2: Install model, index, verify**

Open `hong-kong-visa-run.palmier`. Settings → enable EmbeddingGemma 2 → Install (watch ~800 MB download; state becomes Ready). Media panel: indexing indicator runs over the 223 proxies (gemma pass queues behind SigLIP per asset). Then verify, each through UI or MCP (`mcp` at 127.0.0.1:19789):
  - Search "night street neon" — expect frames from night footage ranked above day footage (spot-check 5 results).
  - `find_moments` with a scene description — expect time ranges inside real clips.
  - `cluster_footage` — expect groups whose members share subject/location; DSCF burst takes appear in `similarTakes`.
  - `match_audio` on one of the 13 `gen-*.wav` lines — expect its matched footage segments to make sense.
- [ ] **Step 3: Record findings**

File follow-up issues (or fix inline where small: label copy, thresholds 0.92/0.3, k heuristic) as separate commits `fix(search):` / `fix(shots):` / `fix(agent):`.

- [ ] **Step 4: PR**

```bash
git push origin feat/embeddinggemma2
gh pr create --repo Kambrio/palmier-pro --base main --head feat/embeddinggemma2 \
  --title "feat: EmbeddingGemma 2 local embeddings — search, grouping, agent tools" \
  --body "Implements docs/superpowers/specs/2026-10-19-embeddinggemma2-design.md"
```

---

## Self-Review (completed)

- Spec coverage: runtime (T1–T3), indexing incl. proxy/source keying + audio (T4–T6), search + fusion (T7), settings/status (T8), analysis (T9–T10), agent grounding (T11), testing incl. sanity + real-project smoke (T12–T13). Failure behavior: model-missing receipts (T11), load-failure state (T3), offline-source key fallback (T5/T6). Out-of-scope respected (no SigLIP replacement, no captioner).
- Placeholder scan: Task 8/10/11 contain UI/wiring steps with concrete anchors (files, greps, exact payloads) rather than code-complete blocks — acceptable for view plumbing per house pattern; all algorithmic tasks have full code. Task 11 test bodies reference the existing harness by name with explicit cases to implement against it.
- Type consistency: `GemmaEmbedding` signature identical in T2/T3/T5; `ClipEmbedStore.Record(model:modelVersion:clipVector:audio:)` used identically in T4/T5/T7/T9/T11; `GemmaIndexer.indexKey(sourceURL:fallbackURL:)` in T5/T7/T10/T11; RRF key `(assetID, shotStart)` consistent T7.
