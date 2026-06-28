import Foundation

/// Resolves a usable OmniVoice python interpreter. Probe order:
/// explicit override → provisioned (App Support) → known dev install.
struct OmniVoiceLocator: Sendable {
    let provisionedPython: URL
    let devPython: URL
    /// Returns true if `python -c "import omnivoice"` succeeds for this interpreter.
    let isUsable: @Sendable (URL) -> Bool

    init(
        provisionedPython: URL = OmniVoicePaths.provisionedPython,
        devPython: URL = OmniVoicePaths.devPython,
        isUsable: @escaping @Sendable (URL) -> Bool = OmniVoiceLocator.probeImportOmniVoice
    ) {
        self.provisionedPython = provisionedPython
        self.devPython = devPython
        self.isUsable = isUsable
    }

    func resolve(override: URL?) -> URL? {
        let candidates = [override, provisionedPython, devPython].compactMap { $0 }
        return candidates.first(where: isUsable)
    }

    /// Default predicate: the interpreter exists and can import omnivoice. Cheap-ish
    /// (imports torch), so callers cache the result in the runtime state machine.
    static func probeImportOmniVoice(_ python: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let proc = Process()
        proc.executableURL = python
        proc.arguments = ["-c", "import omnivoice"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}
