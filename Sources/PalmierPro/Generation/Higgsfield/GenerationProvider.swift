import Foundation

enum GenerationProvider: String, CaseIterable, Sendable {
    case palmier
    case higgsfield
    case omnivoice

    var displayName: String {
        switch self {
        case .palmier: "Palmier"
        case .higgsfield: "Higgsfield (CLI)"
        case .omnivoice: "OmniVoice (Local)"
        }
    }

    private static let key = "io.palmier.pro.generation.provider"

    static var selected: GenerationProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let p = GenerationProvider(rawValue: raw) { return p }
            return .palmier
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Whether the currently-selected provider can run a generation right now. Palmier
    /// needs sign-in + credits; Higgsfield just needs its CLI installed (it uses the user's
    /// own Higgsfield login — no Palmier subscription).
    @MainActor static var canGenerate: Bool {
        switch selected {
        case .palmier: return AccountService.shared.isSignedIn && AccountService.shared.hasCredits
        case .higgsfield: return HiggsfieldCLI.isAvailable
        case .omnivoice:
            OmniVoiceRuntime.shared.refresh()
            if case .ready = OmniVoiceRuntime.shared.state { return true }
            return OmniVoiceRuntime.bundledUV() != nil
        }
    }

    /// Actionable message when `canGenerate` is false, tailored to the selected provider.
    @MainActor static var cannotGenerateReason: String {
        switch selected {
        case .palmier:
            return "Generation needs a Palmier account with credits — tell the user to sign in to Palmier and subscribe, or switch the generation provider to Higgsfield in Settings → Models."
        case .higgsfield:
            return "The Higgsfield CLI isn't installed. Tell the user to install it (and run `higgsfield auth login`), or switch the generation provider to Palmier in Settings → Models."
        case .omnivoice:
            return "The OmniVoice runtime isn't ready. Tell the user to open Settings → Models and install the OmniVoice (Local) runtime."
        }
    }
}

/// Locates the higgsfield binary and reports login state.
enum HiggsfieldCLI {
    static let locator = CLILocator(tool: "higgsfield")

    static var path: String? { locator.resolve(override: nil) }
    static var isAvailable: Bool { path != nil }

    /// Returns true if `higgsfield auth token` prints a token.
    static func isLoggedIn() async -> Bool {
        guard let path else { return false }
        let proc = CLIProcess(executable: path, arguments: ["auth", "token"], timeout: 15)
        let out = (try? await proc.runCapturing())?.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(out ?? "").isEmpty
    }

    /// Launches the browser device-login flow.
    static func login() async throws {
        guard let path else { throw CLIProcessError.launchFailed("higgsfield not found") }
        _ = try await CLIProcess(executable: path, arguments: ["auth", "login"], timeout: 300).runCapturing()
    }
}
