import CoreGraphics
import Foundation

/// Zero-shot shot understanding via the app's SigLIP2 image+text model (the one that powers visual
/// search — no extra download). Scores a frame's image embedding against curated text-prompt banks
/// for shot size, environment/scene, and action. Far more accurate and semantically grounded than
/// `VNClassifyImageRequest`. Degrades to Vision-only when the model isn't installed.
struct SigLIPShotSignal: Sendable {
    var sceneLabels: [String] = []     // top environment/scene phrases
    var action: String?                // best action/content phrase, if confident
    var shotSizeGuess: ShotSize?       // zero-shot shot scale
    var shotSizeConfidence: Float = 0
}

actor SigLIPShotClassifier {
    static let shared = SigLIPShotClassifier()

    /// (label, prompt) banks. Prompts are written in the "a photo of …" style CLIP-likes expect.
    private static let shotSizePrompts: [(ShotSize, String)] = [
        (.extremeCloseUp, "an extreme close-up of a face filling the frame"),
        (.extremeCloseUp, "an extreme close-up of an eye or a small detail"),
        (.closeUp,        "a close-up shot of a person's face and shoulders"),
        (.mediumCloseUp,  "a medium close-up of one person talking to camera, chest up"),
        (.mediumFull,     "a medium full shot of a person from the knees up"),
        (.full,           "a full shot showing a person's entire body head to toe"),
        (.wide,           "a wide shot of several people in a location with surroundings"),
        (.establishing,   "an establishing wide landscape shot with no people"),
        (.establishing,   "an aerial drone establishing shot of a place"),
        (.master,         "a master shot of an entire scene showing where everyone is"),
    ]

    private static let scenePrompts: [String] = [
        "an indoor scene", "an outdoor scene", "an office", "a home interior",
        "a kitchen", "a living room", "a bedroom", "a restaurant or cafe",
        "a retail store", "a classroom", "a film or photo studio", "a stage or concert",
        "a city street", "an urban skyline", "a road or highway", "a parking lot",
        "a nature landscape", "a forest", "mountains", "a beach", "the ocean",
        "a park or garden", "a clear sky", "a sunset", "a night scene", "snow",
        "a desert", "a sports field or court", "a gym", "a crowd of people",
        "the interior of a car", "a product on a table",
    ]

    private static let actionPrompts: [(String, String)] = [
        ("talking to camera", "a person talking directly to the camera"),
        ("interview", "a person being interviewed"),
        ("walking", "a person walking"),
        ("driving", "a person driving a car"),
        ("eating", "people eating or drinking"),
        ("working at a computer", "a person working at a computer"),
        ("presenting", "a person presenting or giving a talk"),
        ("using a phone", "a person using a phone"),
        ("cooking", "a person cooking"),
        ("playing sports", "people playing sports"),
    ]

    private var sizeVecs: [(ShotSize, [Float])]?
    private var sceneVecs: [(String, [Float])]?
    private var actionVecs: [(String, [Float])]?

    private func ensurePromptBanks(_ embedder: VisualEmbedder) {
        guard sizeVecs == nil else { return }
        sizeVecs = Self.shotSizePrompts.compactMap { (s, p) in (try? embedder.encode(text: p)).map { (s, $0) } }
        sceneVecs = Self.scenePrompts.compactMap { p in (try? embedder.encode(text: p)).map { (p, $0) } }
        actionVecs = Self.actionPrompts.compactMap { (l, p) in (try? embedder.encode(text: p)).map { (l, $0) } }
    }

    func classify(image: CGImage, embedder: VisualEmbedder) -> SigLIPShotSignal? {
        ensurePromptBanks(embedder)
        guard let imageVec = try? embedder.encode(image: image) else { return nil }
        var signal = SigLIPShotSignal()

        if let sizeVecs, !sizeVecs.isEmpty {
            // Max-pool the cosine over each size's prompts, then pick the best size.
            var best: [ShotSize: Float] = [:]
            for (size, vec) in sizeVecs {
                if let sim = EmbeddingCodec.cosine(imageVec, vec) {
                    best[size] = max(best[size] ?? -1, sim)
                }
            }
            if let top = best.max(by: { $0.value < $1.value }) {
                let second = best.filter { $0.key != top.key }.map(\.value).max() ?? 0
                signal.shotSizeGuess = top.key
                signal.shotSizeConfidence = top.value - second   // margin = how decisive
            }
        }

        if let sceneVecs {
            signal.sceneLabels = sceneVecs
                .compactMap { (label, vec) in EmbeddingCodec.cosine(imageVec, vec).map { (label, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
                .map { cleanPhrase($0.0) }
        }

        if let actionVecs {
            let ranked = actionVecs
                .compactMap { (label, vec) in EmbeddingCodec.cosine(imageVec, vec).map { (label, $0) } }
                .sorted { $0.1 > $1.1 }
            if let top = ranked.first, top.1 > 0.16 { signal.action = top.0 }
        }
        return signal
    }

    /// Strip the "a/an … " article prefix so phrases read as labels.
    private nonisolated func cleanPhrase(_ p: String) -> String {
        var s = p
        for prefix in ["an ", "a ", "the "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count); break }
        return s
    }
}
