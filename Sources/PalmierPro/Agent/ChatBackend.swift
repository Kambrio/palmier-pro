import Foundation

enum ChatBackend: String, CaseIterable, Sendable {
    case palmier
    case apiKey
    case claudeCLI
    case zai

    var displayName: String {
        switch self {
        case .palmier: "Palmier (sign in)"
        case .apiKey: "Anthropic API key"
        case .claudeCLI: "Claude Code CLI"
        case .zai: "z.ai (GLM Plan)"
        }
    }

    var shortName: String {
        switch self {
        case .palmier: "Palmier"
        case .apiKey: "Anthropic"
        case .claudeCLI: "Claude CLI"
        case .zai: "z.ai"
        }
    }

    private static let key = "io.palmier.pro.chat.backend"

    static var selected: ChatBackend {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let b = ChatBackend(rawValue: raw) { return b }
            // Default prefers the locally-installed Claude Code CLI (subscription, no
            // sign-in/key); `effective` falls back when it isn't available.
            return .claudeCLI
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// The selected backend if available, else the first available in priority order
    /// (claudeCLI, apiKey, zai, palmier) — the local CLI is preferred when installed.
    /// Nil if none available.
    static func effective(selected: ChatBackend, available: Set<ChatBackend>) -> ChatBackend? {
        if available.contains(selected) { return selected }
        for candidate in [ChatBackend.claudeCLI, .apiKey, .zai, .palmier] where available.contains(candidate) {
            return candidate
        }
        return nil
    }
}

/// Model for the Claude Code CLI backend. Separate from the API-key/Palmier model and
/// defaults to Haiku — `claude -p` spends the user's own Claude quota, so never default
/// to Opus/Sonnet.
enum ClaudeCLIModelPreference {
    private static let key = "io.palmier.pro.chat.cli.model"
    static var value: AnthropicModel {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
                let m = AnthropicModel(rawValue: raw) { return m }
            return .haiku45
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

enum ZaiModel: String, CaseIterable, Sendable {
    case glm46 = "glm-4.6"
    case glm52 = "glm-5.2"
    case glm47 = "glm-4.7"

    var displayName: String {
        switch self {
        case .glm46: "GLM-4.6"
        case .glm52: "GLM-5.2"
        case .glm47: "GLM-4.7"
        }
    }
}

enum ZaiModelPreference {
    private static let key = "io.palmier.pro.chat.zai.model"
    static var value: ZaiModel {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
                let m = ZaiModel(rawValue: raw) { return m }
            return .glm46
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// How much tool-result detail to keep in the saved chat transcript. Conversation continuity for the
/// CLI backend is via `--resume` (the CLI keeps its own transcript), so this only affects what the app
/// stores/shows for the user's history — it never changes what's sent to the model or token cost.
/// Images in results are always kept as a compact `[image]` marker (base64 would bloat the project).
enum ChatTranscriptDetail: String, CaseIterable, Sendable {
    case minimal   // just Done/Failed markers (smallest)
    case capped    // tool-result text, truncated (default)
    case full      // full tool-result text

    var displayName: String {
        switch self {
        case .minimal: "Minimal (status only)"
        case .capped:  "Capped (truncated results)"
        case .full:    "Full (complete results)"
        }
    }

    var detail: String {
        switch self {
        case .minimal: "Save only whether each tool succeeded or failed. Smallest project files."
        case .capped:  "Save tool-result text, truncated to keep project files small. Recommended."
        case .full:    "Save complete tool-result text. Larger project files."
        }
    }

    /// Character cap applied to a stored tool result (0 = status only, nil = no cap).
    var textCap: Int? {
        switch self {
        case .minimal: 0
        case .capped:  2_000
        case .full:    nil
        }
    }

    private static let key = "io.palmier.pro.chat.transcriptDetail"
    static var selected: ChatTranscriptDetail {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let v = ChatTranscriptDetail(rawValue: raw) { return v }
            return .capped
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
