import Foundation

/// Owns the Shot Library: runs analysis jobs (serially, off-main), persists results into
/// `editorViewModel.shotLibrary`, and exposes editing mutations for the UI and the agent.
@MainActor
@Observable
final class ShotLibraryManager {
    private unowned let editor: EditorViewModel

    /// assetId → analysis progress (0…1) for the library UI.
    private(set) var progressByAsset: [String: Double] = [:]
    private(set) var isAnalyzing = false

    private var pending: [String] = []
    private var running: String?
    private var job: Task<Void, Never>?
    /// Bumped by cancelAll so a stale drain task exits without clobbering a freshly-started one.
    private var generation = 0

    init(editor: EditorViewModel) { self.editor = editor }

    // MARK: - Queries

    var library: ShotLibrary { editor.shotLibrary }

    /// Video assets eligible for analysis (have on-disk media — source, or a proxy when the source
    /// volume is offline; `run` decodes from the proxy anyway).
    var analyzableAssets: [MediaAsset] {
        editor.mediaAssets.filter { $0.type == .video && editor.trackingInputURL(for: $0.id) != nil }
    }

    func entry(assetId: String) -> ShotEntry? { editor.shotLibrary.entry(assetId: assetId) }

    /// Assets with no entry, or whose source changed since the last analysis.
    var pendingAssetIds: [String] {
        analyzableAssets.compactMap { asset in
            let sig = editor.stableSourceSig(for: asset.id)
            guard let existing = editor.shotLibrary.entry(assetId: asset.id) else { return asset.id }
            return existing.isStale(against: sig) ? asset.id : nil
        }
    }

    // MARK: - Analysis

    /// Queue analysis for one asset. Skips assets already current unless `force`.
    func analyze(assetId: String, force: Bool = false) {
        guard editor.projectURL != nil,
              let asset = editor.mediaAssetsById[assetId], asset.type == .video,
              editor.trackingInputURL(for: assetId) != nil else { return }
        if !force, let existing = editor.shotLibrary.entry(assetId: assetId),
           !existing.isStale(against: editor.stableSourceSig(for: assetId)) { return }
        if running == assetId || pending.contains(assetId) { return }
        pending.append(assetId)
        if job == nil { startDraining() }
    }

    /// Queue analysis for every analyzable asset. `force` re-analyzes even current entries.
    func analyzeAll(force: Bool = false) {
        for asset in analyzableAssets { analyze(assetId: asset.id, force: force) }
    }

    func cancelAll() {
        generation &+= 1
        job?.cancel(); job = nil
        pending.removeAll(); running = nil
        progressByAsset.removeAll()
        isAnalyzing = false
    }

    private func startDraining() {
        isAnalyzing = true
        let gen = generation
        // .utility: footage analysis is background work — keep it on efficiency cores so it never
        // competes with the editor's main-thread rendering during scroll/playback.
        job = Task(priority: .utility) { [weak self] in
            while let self, self.generation == gen, let next = self.dequeue() {
                self.running = next
                await self.run(assetId: next)
                self.running = nil
            }
            // A cancelAll (new generation) owns its own drain — don't clobber its state.
            guard let self, self.generation == gen else { return }
            self.recomputeIdentityGroups()   // once per batch, not per asset
            self.editor.onPersistentStateChanged?()
            self.job = nil
            self.isAnalyzing = false
        }
    }

    private func dequeue() -> String? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    private func run(assetId: String) async {
        guard let projectURL = editor.projectURL,
              let asset = editor.mediaAssetsById[assetId],
              let decodeURL = editor.trackingInputURL(for: assetId) else { return }
        progressByAsset[assetId] = 0

        var transcript: TranscriptionResult?
        if asset.hasAudio, let audioURL = editor.sourcePreferredInputURL(for: assetId) {
            let engineTag = TranscriptCache.currentEngineTag()
            transcript = try? await TranscriptCache.shared.transcript(
                for: audioURL, isVideo: true, range: nil, engineTag: engineTag, preferredLocale: nil)
        }

        let input = ShotAnalyzer.Input(
            assetId: assetId, url: decodeURL, durationSeconds: asset.duration,
            sourceSig: editor.stableSourceSig(for: assetId), projectURL: projectURL)

        let entry = await ShotAnalyzer.analyze(input, transcript: transcript) { [weak self] p in
            Task { @MainActor [weak self] in self?.progressByAsset[assetId] = p }
        }
        progressByAsset[assetId] = nil
        guard var entry else {
            Log.project.error("shot analysis produced no result id=\(assetId.prefix(8))")
            return
        }
        // Preserve user edits to name/summary/labels/per-frame descriptions/shot sizes across a re-analysis.
        if let prior = editor.shotLibrary.entry(assetId: assetId), prior.edited {
            entry.summary = prior.summary
            entry.displayName = prior.displayName
            entry.labels = prior.labels
            entry.shotSize = prior.shotSize
            for pf in prior.frames {
                if let i = entry.frames.firstIndex(where: { $0.position == pf.position }) {
                    entry.frames[i].description = pf.description
                    entry.frames[i].shotSize = pf.shotSize
                }
            }
            entry.edited = true
        }
        editor.shotLibrary.upsert(entry)
        editor.onPersistentStateChanged?()
    }

    // MARK: - Editing mutations (UI + agent)

    func setSummary(assetId: String, _ text: String) {
        mutate(assetId) { $0.summary = text; $0.edited = true }
    }

    func setDisplayName(assetId: String, _ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(assetId) { $0.displayName = (trimmed?.isEmpty == true) ? nil : trimmed; $0.edited = true }
    }

    func setFrameDescription(assetId: String, position: ShotPosition, _ text: String) {
        mutate(assetId) { entry in
            if let i = entry.frames.firstIndex(where: { $0.position == position }) {
                entry.frames[i].description = text
            }
            entry.edited = true
        }
    }

    /// Override the detected shot size for one frame (the user's correction beats auto-detect). The
    /// entry's representative size tracks the middle frame. Sticks across re-analysis via `edited`.
    func setFrameShotSize(assetId: String, position: ShotPosition, _ size: ShotSize) {
        mutate(assetId) { entry in
            if let i = entry.frames.firstIndex(where: { $0.position == position }) {
                entry.frames[i].shotSize = size
            }
            if position == .median { entry.shotSize = size }
            entry.edited = true
        }
    }

    func toggleLabel(assetId: String, _ rawLabel: String) {
        let label = ShotLabels.normalize(rawLabel)
        guard !label.isEmpty else { return }
        mutate(assetId) { entry in
            if let i = entry.labels.firstIndex(of: label) { entry.labels.remove(at: i) }
            else { entry.labels.append(label) }
            entry.edited = true
        }
    }

    /// Toggle a label, creating a minimal shot entry first if the footage hasn't been analyzed —
    /// so footage can be labeled directly from the timeline before (or without) analysis. The bare
    /// entry is `edited` + has no sourceSig, so a later analysis still runs and preserves the label.
    func toggleLabelEnsuringEntry(assetId: String, _ rawLabel: String) {
        if editor.shotLibrary.entry(assetId: assetId) == nil {
            editor.shotLibrary.upsert(ShotEntry(assetId: assetId))
        }
        toggleLabel(assetId: assetId, rawLabel)
    }

    /// Override the representative shot size for the footage (entry + middle frame). Sticks across
    /// re-analysis via `edited`.
    func setShotSize(assetId: String, _ size: ShotSize) {
        mutate(assetId) { entry in
            entry.shotSize = size
            if let i = entry.frames.firstIndex(where: { $0.position == .median }) {
                entry.frames[i].shotSize = size
            }
            entry.edited = true
        }
    }

    func setLabels(assetId: String, _ labels: [String]) {
        let normalized = labels.map(ShotLabels.normalize).filter { !$0.isEmpty }
        mutate(assetId) { $0.labels = Array(NSOrderedSet(array: normalized).array as? [String] ?? []); $0.edited = true }
    }

    func removeEntry(assetId: String) {
        editor.shotLibrary.remove(assetId: assetId)
        if let url = editor.projectURL { ShotThumbnailStore.remove(assetId: assetId, projectURL: url) }
        editor.onPersistentStateChanged?()
    }

    private func mutate(_ assetId: String, _ change: (inout ShotEntry) -> Void) {
        guard let i = editor.shotLibrary.entries.firstIndex(where: { $0.assetId == assetId }) else { return }
        change(&editor.shotLibrary.entries[i])
        editor.onPersistentStateChanged?()
    }

    // MARK: - Identity grouping

    /// Single-link clusters entries by face-embedding cosine similarity, assigning `personGroup` ids.
    /// Entries sharing a group feature the same person — used to relate footage to a subject.
    func recomputeIdentityGroups(threshold: Float = 0.82) {
        let embeddings = editor.shotLibrary.entries.map { EmbeddingCodec.decode($0.faceEmbedding) }
        let groups = ShotIdentityClustering.groups(for: embeddings, threshold: threshold)
        for i in editor.shotLibrary.entries.indices {
            editor.shotLibrary.entries[i].personGroup = groups[i]
        }
    }
}

/// Pure single-link clustering of optional face embeddings into person-group ids. Entries without an
/// embedding, or in a singleton cluster, get `nil` (no shared identity to report).
enum ShotIdentityClustering {
    static func groups(for embeddings: [[Float]?], threshold: Float) -> [Int?] {
        let withFaces: [(idx: Int, vec: [Float])] = embeddings.enumerated().compactMap { i, e in
            e.map { (i, $0) }
        }
        var result = [Int?](repeating: nil, count: embeddings.count)
        guard withFaces.count > 1 else { return result }

        var groupOf = [Int](repeating: -1, count: withFaces.count)
        var nextGroup = 0
        for a in withFaces.indices {
            if groupOf[a] == -1 { groupOf[a] = nextGroup; nextGroup += 1 }
            for b in (a + 1)..<withFaces.count {
                if let sim = EmbeddingCodec.cosine(withFaces[a].vec, withFaces[b].vec), sim >= threshold {
                    let target = groupOf[a]
                    let other = groupOf[b]
                    if other == -1 { groupOf[b] = target }
                    else if other != target {
                        for k in groupOf.indices where groupOf[k] == other { groupOf[k] = target }
                    }
                }
            }
        }
        var counts: [Int: Int] = [:]
        for g in groupOf { counts[g, default: 0] += 1 }
        for (n, item) in withFaces.enumerated() {
            let g = groupOf[n]
            result[item.idx] = (counts[g] ?? 0) > 1 ? g : nil
        }
        return result
    }
}
