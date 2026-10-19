import Foundation

@MainActor
@Observable
final class GemmaModelManager {
    enum State: Equatable {
        case unknown, notInstalled, downloading(Double), preparing, ready, failed(String)
    }

    struct ModelFactories: Sendable {
        var load: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> any GemmaEmbedding
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

    // Test-only enable switch; skips the UserDefaults write of setEnabled(_:).
    func setEnabledInternal(_ value: Bool) { enabled = value }

    func prepare() async {
        guard enabled, state == .unknown else { return }
        // Claim the slot before the first await so overlapping launch callers can't both load.
        state = .preparing
        let factories = self.factories
        let installed = await Task.detached(priority: .userInitiated) { factories.isInstalled() }.value
        guard installed else { state = .notInstalled; return }
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
        let factories = self.factories
        await Task.detached(priority: .userInitiated) { factories.delete() }.value
    }

    private func load() async {
        do {
            let embedder = try await factories.load { _ in }
            guard enabled else { state = .unknown; return }
            self.embedder = embedder
            state = .ready
            Log.search.notice("gemma model ready dim=\(embedder.dim)")
        } catch {
            state = .failed(error.localizedDescription)
            Log.search.error("gemma model load failed: \(error.localizedDescription)")
        }
    }
}

#if BUNDLED_SPEECH
import CoreGraphics
import CoreImage
import CoreMedia
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

enum LiveGemmaEmbedderFactory {
    static let hubID = "mlx-community/embeddinggemma-2-8bit"

    static func isInstalled() -> Bool {
        guard let repo = Repo.ID(rawValue: hubID),
              let commit = HubCache.default.resolveRevision(repo: repo, kind: .model, ref: "main"),
              let snapshot = try? HubCache.default.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        else { return false }
        return FileManager.default.fileExists(atPath: snapshot.appending(component: "config.json").path)
    }

    static func delete() {
        guard let repo = Repo.ID(rawValue: hubID) else { return }
        try? FileManager.default.removeItem(at: HubCache.default.repoDirectory(repo: repo, kind: .model))
    }

    static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> any GemmaEmbedding {
        let resolved = try await Task.detached(priority: .userInitiated) {
            try await resolve(
                configuration: ModelConfiguration(id: hubID),
                from: #hubDownloader(), useLatest: false,
                progressHandler: { progress($0.fractionCompleted) })
        }.value
        let underlying = try await EmbeddingGemma2Embedding(
            modelDirectory: resolved.modelDirectory, tokenizerLoader: #huggingFaceTokenizerLoader())
        progress(1)
        return try await MLXGemmaEmbedder(underlying: underlying)
    }
}

final class MLXGemmaEmbedder: GemmaEmbedding, Sendable {
    let dim: Int
    private let underlying: EmbeddingGemma2Embedding

    init(underlying: EmbeddingGemma2Embedding) async throws {
        self.underlying = underlying
        dim = try await underlying.embed(.init(text: "warm up"), task: .document).count
    }

    func embedText(_ text: String, task: GemmaTask) async throws -> [Float] {
        try await underlying.embed(.init(text: text), task: task.libraryTask)
    }

    func embedImages(_ images: [CGImage]) async throws -> [[Float]] {
        let inputs: [EmbeddingGemma2Embedding.Input] = images.map {
            .init([.image(.ciImage(CIImage(cgImage: $0)))])
        }
        return try await underlying.embed(inputs, task: .document)
    }

    func embedVideo(_ frames: [CGImage]) async throws -> [Float] {
        let parts = frames.enumerated().map { index, frame in
            UserInput.VideoFrame(
                image: .ciImage(CIImage(cgImage: frame)),
                timeStamp: CMTime(seconds: Double(index), preferredTimescale: 600))
        }
        return try await underlying.embed(.init([.video(.frames(parts))]), task: .document)
    }

    func embedAudio(_ samples: [Float], sampleRate: Int) async throws -> [Float] {
        try await underlying.embed(.init([.audio(.array(MLXArray(samples)))]), task: .document)
    }
}

private extension GemmaTask {
    var libraryTask: EmbeddingGemma2Embedding.Task {
        switch self {
        case .searchQuery: .searchQuery
        case .document: .document
        case .clustering: .clustering
        }
    }
}
#else
enum LiveGemmaEmbedderFactory {
    static func isInstalled() -> Bool { false }
    static func delete() {}
    static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> any GemmaEmbedding {
        throw GemmaUnavailableError.modelNotBuilt
    }
}
#endif

enum GemmaUnavailableError: Error, LocalizedError {
    case modelNotBuilt

    var errorDescription: String? {
        "Gemma embedding requires the BundledSpeech build."
    }
}
