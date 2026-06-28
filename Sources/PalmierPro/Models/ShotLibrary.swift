import Foundation

/// Where in a clip's duration a sampled frame was taken.
enum ShotPosition: String, Codable, Sendable, CaseIterable {
    case q10, median, q90

    /// Fraction of the asset's duration this frame samples.
    var fraction: Double {
        switch self {
        case .q10:    0.10
        case .median: 0.50
        case .q90:    0.90
        }
    }

    var label: String {
        switch self {
        case .q10:    "10%"
        case .median: "Middle"
        case .q90:    "90%"
        }
    }
}

/// Coarse cinematographic shot scale, derived on-device from the largest subject's frame coverage.
enum ShotSize: String, Codable, Sendable, CaseIterable {
    case closeUp, medium, wide, establishing, unknown

    var displayName: String {
        switch self {
        case .closeUp:      "Close-up"
        case .medium:       "Medium"
        case .wide:         "Wide"
        case .establishing: "Establishing"
        case .unknown:      "—"
        }
    }
}

/// One predefined editorial label. Users may also attach free-form custom labels.
/// `colorToken` names an `AppTheme.Label` hue (resolved in the view layer) for color-coding.
struct ShotLabelDef: Sendable, Equatable, Identifiable {
    let id: String        // canonical, lowercased
    let title: String
    let hint: String
    let systemImage: String
    let colorToken: String
}

enum ShotLabels {
    static let key = "key"
    static let skip = "skip"

    /// Built-in labels offered in the editor and to the agent.
    static let all: [ShotLabelDef] = [
        .init(id: "key", title: "Key", hint: "Drives the story — prioritize in the edit.", systemImage: "key.fill", colorToken: "amber"),
        .init(id: "skip", title: "Skip", hint: "Don't use this footage.", systemImage: "nosign", colorToken: "red"),
        .init(id: "hero", title: "Hero", hint: "Best-quality showcase shot.", systemImage: "star.fill", colorToken: "orange"),
        .init(id: "broll", title: "B-roll", hint: "Cutaway / supporting coverage.", systemImage: "film", colorToken: "blue"),
        .init(id: "interview", title: "Interview", hint: "On-camera speech / talking head.", systemImage: "person.wave.2.fill", colorToken: "teal"),
        .init(id: "establishing", title: "Establishing", hint: "Sets the scene or location.", systemImage: "mountain.2.fill", colorToken: "green"),
        .init(id: "reaction", title: "Reaction", hint: "Emotional or reaction beat.", systemImage: "face.smiling", colorToken: "pink"),
        .init(id: "transition", title: "Transition", hint: "Movement useful as a cut point.", systemImage: "arrow.left.arrow.right", colorToken: "purple"),
    ]

    static func def(_ id: String) -> ShotLabelDef? { all.first { $0.id == normalize(id) } }

    /// Lowercase, trimmed, single-spaced canonical form.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

/// One sampled frame's analysis: the on-device structured signals plus an editable description.
struct ShotFrame: Codable, Sendable, Equatable {
    var position: ShotPosition
    var timeSeconds: Double
    /// Natural-language description (heuristic baseline; refined by the agent or the user).
    var description: String?
    /// Apple Vision scene/object classification labels (most-confident first).
    var sceneLabels: [String] = []
    /// YOLO object labels present in the frame (deduped).
    var objects: [String] = []
    var shotSize: ShotSize = .unknown
    var people: Int = 0
    var faceQuality: Double?
    /// Best-guess action/content (e.g. "talking to camera"), from zero-shot SigLIP scoring.
    var action: String?
    /// Relative path within the package to the stored JPEG thumbnail.
    var thumbnailRelPath: String?

    init(position: ShotPosition, timeSeconds: Double) {
        self.position = position
        self.timeSeconds = timeSeconds
    }

    // Tolerant decode: only position + timeSeconds are required; the rest default so adding fields
    // later never breaks an older project's shot-library.json.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(ShotPosition.self, forKey: .position)
        timeSeconds = try c.decodeIfPresent(Double.self, forKey: .timeSeconds) ?? 0
        description = try c.decodeIfPresent(String.self, forKey: .description)
        sceneLabels = try c.decodeIfPresent([String].self, forKey: .sceneLabels) ?? []
        objects = try c.decodeIfPresent([String].self, forKey: .objects) ?? []
        shotSize = try c.decodeIfPresent(ShotSize.self, forKey: .shotSize) ?? .unknown
        people = try c.decodeIfPresent(Int.self, forKey: .people) ?? 0
        faceQuality = try c.decodeIfPresent(Double.self, forKey: .faceQuality)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        thumbnailRelPath = try c.decodeIfPresent(String.self, forKey: .thumbnailRelPath)
    }
}

/// Per-footage shot analysis. One entry per video asset, keyed by assetId.
struct ShotEntry: Codable, Sendable, Equatable, Identifiable {
    var assetId: String
    var id: String { assetId }

    /// Source identity (mtime+size hash) the analysis was produced from — for staleness checks.
    var sourceSig: String?
    /// A short, meaningful name for the footage, surfaced on the timeline and media tiles.
    var displayName: String?
    /// Overall footage description (editable).
    var summary: String = ""
    /// Editorial tags (predefined ids like "key"/"skip" plus custom strings).
    var labels: [String] = []
    /// Representative shot scale (from the middle frame).
    var shotSize: ShotSize?
    /// Representative number of people on screen.
    var people: Int?
    var hasSpeech: Bool?
    var transcriptExcerpt: String?
    var durationSeconds: Double?
    var frames: [ShotFrame] = []
    var analyzedAt: Date?
    /// True once the user (or agent) edits the summary/name/labels — protects manual work from
    /// being overwritten by an automatic re-analysis.
    var edited: Bool = false
    /// Compact Float16 base64 of the best face's Vision feature print, for identity grouping.
    var faceEmbedding: String?
    /// Identity cluster id; entries sharing a group feature the same person.
    var personGroup: Int?

    init(assetId: String) { self.assetId = assetId }

    // Tolerant decode: only assetId is required; everything else defaults so the schema can grow.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try c.decode(String.self, forKey: .assetId)
        sourceSig = try c.decodeIfPresent(String.self, forKey: .sourceSig)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        shotSize = try c.decodeIfPresent(ShotSize.self, forKey: .shotSize)
        people = try c.decodeIfPresent(Int.self, forKey: .people)
        hasSpeech = try c.decodeIfPresent(Bool.self, forKey: .hasSpeech)
        transcriptExcerpt = try c.decodeIfPresent(String.self, forKey: .transcriptExcerpt)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        frames = try c.decodeIfPresent([ShotFrame].self, forKey: .frames) ?? []
        analyzedAt = try c.decodeIfPresent(Date.self, forKey: .analyzedAt)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        faceEmbedding = try c.decodeIfPresent(String.self, forKey: .faceEmbedding)
        personGroup = try c.decodeIfPresent(Int.self, forKey: .personGroup)
    }

    /// Whether this entry should be re-analyzed given the asset's current source signature.
    func isStale(against sig: String?) -> Bool {
        guard let sig else { return false }
        return sourceSig != sig
    }

    var isSkipped: Bool { labels.contains(ShotLabels.skip) }
    var isKey: Bool { labels.contains(ShotLabels.key) }
}

/// Project-scoped library of per-footage shot analyses, persisted as `shot-library.json`.
struct ShotLibrary: Codable, Sendable, Equatable {
    var version: Int = 1
    var entries: [ShotEntry] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([ShotEntry].self, forKey: .entries) ?? []
    }

    func entry(assetId: String) -> ShotEntry? { entries.first { $0.assetId == assetId } }

    mutating func upsert(_ entry: ShotEntry) {
        if let i = entries.firstIndex(where: { $0.assetId == entry.assetId }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }

    mutating func remove(assetId: String) {
        entries.removeAll { $0.assetId == assetId }
    }
}
