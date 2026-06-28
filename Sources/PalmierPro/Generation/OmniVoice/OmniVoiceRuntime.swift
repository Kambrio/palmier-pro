import Foundation
import Observation

@MainActor
@Observable
final class OmniVoiceRuntime {
    static let shared = OmniVoiceRuntime()

    enum State: Equatable {
        case unknown
        case notInstalled
        case provisioning(Double, String)
        case ready(URL)            // resolved python interpreter
        case error(String)
    }

    private(set) var state: State = .unknown

    /// User-set interpreter path override (Settings). Persisted in UserDefaults.
    var overridePath: String? {
        get { UserDefaults.standard.string(forKey: Self.overrideKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.overrideKey) }
    }
    private static let overrideKey = "io.palmier.pro.omnivoice.pythonOverride"

    private init() {}

    var resolvedPython: URL? {
        if case .ready(let url) = state { return url }
        return nil
    }

    /// Cheap-ish disk/import probe (no network). Updates `state`.
    func refresh() {
        switch state {
        case .provisioning, .ready: return
        default: break
        }
        let override = overridePath.map { URL(fileURLWithPath: $0) }
        if let python = OmniVoiceLocator().resolve(override: override) {
            state = .ready(python)
        } else if state == .unknown {
            state = .notInstalled
        }
    }

    /// Resolve or provision. Throws if provisioning fails.
    func ensureReady() async throws -> URL {
        refresh()
        if case .ready(let url) = state { return url }
        return try await provision()
    }

    @discardableResult
    func provision() async throws -> URL {
        guard let uv = Self.bundledUV() else {
            state = .error("Bundled uv binary missing.")
            throw OmniVoiceError.runtimeUnavailable("Bundled uv binary missing.")
        }
        state = .provisioning(0, "Starting")
        try? FileManager.default.createDirectory(at: OmniVoicePaths.installRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: OmniVoicePaths.hfCache, withIntermediateDirectories: true)
        let provisioner = OmniVoiceProvisioner(uvPath: uv)
        do {
            let python = try await provisioner.provision { [weak self] value, label in
                Task { @MainActor in
                    guard let self, case .provisioning = self.state else { return }
                    self.state = .provisioning(value, label)
                }
            }
            Self.clearQuarantine(at: OmniVoicePaths.installRoot)
            state = .ready(python)
            return python
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    static func bundledUV() -> URL? {
        Bundle.module.url(forResource: "uv", withExtension: nil, subdirectory: "bin")
    }

    static func bundledWorker() -> URL? {
        Bundle.module.url(forResource: "omnivoice_worker", withExtension: "py", subdirectory: "OmniVoice")
    }

    /// Freshly-provisioned python + torch dylibs carry a quarantine xattr; clear it so
    /// Gatekeeper doesn't kill the spawned interpreter. They run as a child process,
    /// so Palmier's own hardened runtime / library-validation never gates them.
    static func clearQuarantine(at root: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-dr", "com.apple.quarantine", root.path]
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }
}

enum OmniVoiceError: LocalizedError {
    case runtimeUnavailable(String)
    case workerMissing
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let m): return m
        case .workerMissing: return "OmniVoice worker script missing from the app bundle."
        case .generationFailed(let m): return m
        }
    }
}
