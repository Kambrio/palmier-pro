// Sources/PalmierPro/Utilities/CLIProcess.swift
import Foundation

enum CLIProcessError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "Could not launch CLI: \(m)"
        case .nonZeroExit(let code, let stderr):
            return stderr.isEmpty ? "CLI exited with code \(code)" : stderr
        case .timedOut: return "CLI timed out."
        }
    }
}

/// Thin async wrapper over Process. Streams stdout as lines; captures stderr.
struct CLIProcess {
    let executable: String
    let arguments: [String]
    var environment: [String: String]? = nil
    var timeout: TimeInterval = 600

    /// Runs to completion and returns full stdout. Throws on non-zero exit or timeout.
    func runCapturing() async throws -> String {
        var out = ""
        for try await line in streamLines() { out += line + "\n" }
        return out
    }

    /// Streams stdout line by line. Throws `nonZeroExit` (with stderr) if the process fails.
    func streamLines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stderrData = LockedData()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stderrData.append(chunk) }
            }

            let lineBuffer = LockedData()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lineBuffer.append(chunk)
                lineBuffer.drainLines { continuation.yield($0) }
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                if let remainder = lineBuffer.drainRemainder() {
                    continuation.yield(remainder)
                }
                let stderrText = String(decoding: stderrData.snapshot(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: CLIProcessError.nonZeroExit(
                        code: proc.terminationStatus, stderr: stderrText))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: CLIProcessError.launchFailed(error.localizedDescription))
                return
            }

            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    process.terminate()
                    continuation.finish(throwing: CLIProcessError.timedOut)
                }
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning { process.terminate() }
            }
        }
    }
}

/// Tiny thread-safe Data accumulator for the stderr readability handler.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }

    /// Calls `emit` for each complete newline-terminated line, consuming them from `data`.
    func drainLines(_ emit: (String) -> Void) {
        lock.lock()
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: data.startIndex..<nl)
            data.removeSubrange(data.startIndex...nl)
            lock.unlock()
            emit(String(decoding: lineData, as: UTF8.self))
            lock.lock()
        }
        lock.unlock()
    }

    /// Returns any remaining (unterminated) data as a String, or nil if empty.
    func drainRemainder() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
