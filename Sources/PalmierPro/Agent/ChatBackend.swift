import Foundation

enum ChatBackend: String, CaseIterable, Sendable {
    case palmier
    case apiKey
    case claudeCLI

    var displayName: String {
        switch self {
        case .palmier: "Palmier (sign in)"
        case .apiKey: "Anthropic API key"
        case .claudeCLI: "Claude Code CLI"
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
    /// (claudeCLI, apiKey, palmier) — the local CLI is preferred when installed.
    /// Nil if none available.
    static func effective(selected: ChatBackend, available: Set<ChatBackend>) -> ChatBackend? {
        if available.contains(selected) { return selected }
        for candidate in [ChatBackend.claudeCLI, .apiKey, .palmier] where available.contains(candidate) {
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
