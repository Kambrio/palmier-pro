import Foundation

enum GenerationProvider: String, CaseIterable, Sendable {
    case palmier
    case higgsfield

    var displayName: String {
        switch self {
        case .palmier: "Palmier"
        case .higgsfield: "Higgsfield (CLI)"
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
