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

    /// WhisperKit downloads into `downloadBase/models/<repo-id>/<variant>` (HubApi.localRepoLocation +
    /// WhisperKit.download appending the variant folder). We pass the model repo as the variant, so the
    /// asset folder (where the `.mlmodelc` bundles live, and what must be the load `modelFolder`) is this.
    static func variantFolder(base: URL, repo: String) -> URL {
        base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
    }

    /// Canonical asset folder for a model under the shared download base.
    static func folder(for model: WhisperModel) -> URL {
        variantFolder(base: modelsDirectory, repo: model.repo)
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
        // WhisperKit loads MelSpectrogram/AudioEncoder/TextDecoder as `.mlmodelc` bundles from this folder;
        // a non-empty dir (e.g. a stray `.cache`) is not enough — require an actual compiled model.
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    /// True when the active model is downloaded and ready for the router.
    var activeModelAvailable: Bool {
        guard let m = WhisperModelCatalog.model(id: activeModelId) else { return false }
        return Self.isDownloaded(m)
    }

    func download(_ model: WhisperModel) {
        guard downloadTasks[model.id] == nil else { return }
        states[model.id] = .downloading(0)
        let base = Self.modelsDirectory
        let folder = Self.folder(for: model)
        downloadTasks[model.id] = Task { [weak self] in
            do {
                let returned = try await WhisperKitRunner.download(repo: model.repo, to: base) { [weak self] p in
                    guard let s = self else { return }
                    Task { @MainActor in
                        if case .downloading = s.states[model.id] { s.states[model.id] = .downloading(p) }
                    }
                }
                if returned.standardizedFileURL != folder.standardizedFileURL {
                    Log.transcription.warning("Whisper download path \(returned.path) != expected \(folder.path)")
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
