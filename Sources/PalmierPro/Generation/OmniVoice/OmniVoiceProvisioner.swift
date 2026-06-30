import Foundation

/// Builds a self-contained OmniVoice runtime under `installRoot` using a bundled `uv`:
/// pinned CPython → venv → `pip install omnivoice` → snapshot-download weights.
/// Process execution is injected via `run` so the orchestration is unit-testable.
struct OmniVoiceProvisioner: Sendable {
    struct Step: Sendable {
        let argv: [String]
        let env: [String: String]
    }

    let uvPath: URL
    let installRoot: URL
    let hfCache: URL
    let pythonPin: String
    let omniVoiceVersion: String
    let run: @Sendable (Step) async throws -> Void

    init(
        uvPath: URL,
        installRoot: URL = OmniVoicePaths.installRoot,
        hfCache: URL = OmniVoicePaths.hfCache,
        pythonPin: String = OmniVoicePaths.pythonPin,
        omniVoiceVersion: String = OmniVoicePaths.omniVoiceVersion,
        run: (@Sendable (Step) async throws -> Void)? = nil
    ) {
        self.uvPath = uvPath
        self.installRoot = installRoot
        self.hfCache = hfCache
        self.pythonPin = pythonPin
        self.omniVoiceVersion = omniVoiceVersion
        self.run = run ?? OmniVoiceProvisioner.runWithCLIProcess(uvPath: uvPath)
    }

    var venvPython: URL { installRoot.appendingPathComponent(".venv/bin/python3") }

    /// Runs all steps in order, reporting fractional progress + a human label.
    /// Returns the provisioned venv python on success. The caller creates
    /// `installRoot`/`hfCache` first (keeps this pure + unit-testable with fake paths).
    @discardableResult
    func provision(progress: @Sendable (Double, String) -> Void) async throws -> URL {
        let venv = installRoot.appendingPathComponent(".venv")
        let hf = hfCache.path
        let steps: [(Step, String)] = [
            (Step(argv: ["python", "install", pythonPin], env: [:]),
             "Installing Python \(pythonPin)"),
            (Step(argv: ["venv", "--python", pythonPin, venv.path], env: [:]),
             "Creating environment"),
            (Step(argv: ["pip", "install", "--python", venvPython.path, "omnivoice==\(omniVoiceVersion)"], env: [:]),
             "Installing OmniVoice (PyTorch — this is large)"),
            (Step(argv: ["run", "--python", venvPython.path, "python", "-c",
                         "from huggingface_hub import snapshot_download; snapshot_download('k2-fsa/OmniVoice')"],
                  env: ["HF_HOME": hf]),
             "Downloading model weights"),
        ]

        for (i, item) in steps.enumerated() {
            progress(Double(i) / Double(steps.count), item.1)
            do {
                try await run(item.0)
            } catch {
                throw OmniVoiceError.runtimeUnavailable("'\(item.1)' failed: \(error.localizedDescription)")
            }
        }
        progress(1.0, "Ready")
        return venvPython
    }

    /// Default executor: each Step becomes a `uv` invocation via CLIProcess.
    static func runWithCLIProcess(uvPath: URL) -> @Sendable (Step) async throws -> Void {
        { step in
            var env = ProcessInfo.processInfo.environment
            for (k, v) in step.env { env[k] = v }
            _ = try await CLIProcess(
                executable: uvPath.path, arguments: step.argv,
                environment: env, timeout: 3600
            ).runCapturing()
        }
    }
}
