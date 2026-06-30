import Foundation

/// Runs one OmniVoice job through the bundled worker and returns the WAV path(s)
/// that completed. Structurally analogous to HiggsfieldGenerationProvider.generate.
struct OmniVoiceGenerationProvider {

    /// - Parameter onProgress: called on the main actor for each parsed progress line.
    @MainActor
    static func generate(
        job: OmniVoiceJob,
        python: URL,
        onProgress: (@MainActor (OmniVoiceProgress) -> Void)? = nil
    ) async throws -> [String] {
        guard let worker = OmniVoiceRuntime.bundledWorker() else {
            throw OmniVoiceError.workerMissing
        }

        let payload = try JSONEncoder().encode(job)
        let jsonInput = String(decoding: payload, as: UTF8.self)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnivoice-job-\(UUID().uuidString).json")
        try jsonInput.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = OmniVoicePaths.hfCache.path

        // Run: /bin/sh -c '"python" "worker.py" < "job.json"' so stdin is the job file.
        let shCommand = "\(shQuote(python.path)) \(shQuote(worker.path)) < \(shQuote(tmp.path))"
        let proc = CLIProcess(
            executable: "/bin/sh",
            arguments: ["-c", shCommand],
            environment: env,
            idleTimeout: 600
        )

        var completed = false
        var segmentErrors: [String] = []
        for try await line in proc.streamLines() {
            guard let progress = OmniVoiceProgress.parse(line) else { continue }
            onProgress?(progress)
            if case .complete = progress { completed = true }
            if case .segmentError(_, let message) = progress { segmentErrors.append(message) }
        }

        let produced = job.segments
            .map(\.output)
            .filter { FileManager.default.fileExists(atPath: $0) }

        guard completed, !produced.isEmpty else {
            throw OmniVoiceError.generationFailed(Self.noAudioFailureMessage(errors: segmentErrors))
        }
        return produced
    }

    /// Message thrown when the worker finishes without usable output. Includes any per-segment
    /// errors the worker reported (e.g. a rejected voice-design `instruct`) so the cause is
    /// actionable instead of an opaque "no audio" that surfaces as a silent clip.
    static func noAudioFailureMessage(errors: [String]) -> String {
        guard !errors.isEmpty else { return "Worker produced no audio." }
        return "Worker produced no audio. " + errors.joined(separator: " | ")
    }

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
