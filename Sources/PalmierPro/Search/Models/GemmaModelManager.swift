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

    func prepare() async {
        guard state == .unknown else { return }
        let factories = self.factories
        let installed = await Task.detached(priority: .userInitiated) { factories.isInstalled() }.value
        guard installed else { state = .notInstalled; return }
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
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
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

    // mlx-swift-lm 3.32.3 has no EmbeddingGemma 2 class; loads the registry's gemma3 text path.
    static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> any GemmaEmbedding {
        let container = try await Task.detached(priority: .userInitiated) { () -> EmbedderModelContainer in
            try await EmbedderModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: .init(id: hubID),
                progressHandler: { progress($0.fractionCompleted) })
        }.value
        progress(1)
        return try await MLXGemmaEmbedder(container: container)
    }
}

final class MLXGemmaEmbedder: GemmaEmbedding, Sendable {
    let dim: Int
    private let container: EmbedderModelContainer

    init(container: EmbedderModelContainer) async throws {
        self.container = container
        dim = try await Self.embed(container: container, text: "warm up", task: .document).count
    }

    func embedText(_ text: String, task: GemmaTask) async throws -> [Float] {
        try await Self.embed(container: container, text: text, task: task)
    }

    func embedImages(_ images: [CGImage]) async throws -> [[Float]] {
        throw GemmaUnavailableError.modalityUnsupported("images")
    }

    func embedVideo(_ frames: [CGImage]) async throws -> [Float] {
        throw GemmaUnavailableError.modalityUnsupported("video")
    }

    func embedAudio(_ samples: [Float], sampleRate: Int) async throws -> [Float] {
        throw GemmaUnavailableError.modalityUnsupported("audio")
    }

    // EmbeddingGemma instruction prefixes; GemmaTask rawValues name the non-query tasks.
    private static func prompt(_ text: String, task: GemmaTask) -> String {
        switch task {
        case .searchQuery: "task: search result | query: \(text)"
        case .document, .clustering: "task: \(task.rawValue) | text: \(text)"
        }
    }

    private static func embed(container: EmbedderModelContainer, text: String, task: GemmaTask) async throws -> [Float] {
        let formatted = prompt(text, task: task)
        return try await Task.detached(priority: .userInitiated) { () -> [Float] in
            try await container.perform { context in
                let ids = context.tokenizer.encode(text: formatted, addSpecialTokens: true)
                let inputs = MLXArray([ids])
                let mask = MLXArray.ones([1, ids.count])
                let output = context.model(inputs, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
                // pooledOutput is already projected and L2-normalized; extra layerNorm would skew it.
                let pooled = context.pooling(output, mask: mask, normalize: true, applyLayerNorm: false)
                pooled.eval()
                return pooled.asArray(Float.self)
            }
        }.value
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
    case modalityUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .modelNotBuilt: "Gemma embedding requires the BundledSpeech build."
        case .modalityUnsupported(let modality): "Gemma embedding for \(modality) is not available in this mlx-swift-lm release."
        }
    }
}
