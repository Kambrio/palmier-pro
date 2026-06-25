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
    /// Working directory for the child process. The Claude CLI discovers project skills
    /// from `<cwd>/.claude/skills`, so the chat backend points this at the skills workspace.
    var workingDirectory: URL? = nil
    var timeout: TimeInterval = 600
    /// When set, replaces the absolute `timeout` with an inactivity watchdog: the process is
    /// killed only after this many seconds with NO stdout/stderr output. Right for streaming
    /// agentic turns that legitimately run long while actively producing output.
    var idleTimeout: TimeInterval? = nil

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
            if let workingDirectory { process.currentDirectoryURL = workingDirectory }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let lastActivity = LockedTimestamp()

            let stderrData = LockedData()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { lastActivity.touch(); stderrData.append(chunk) }
            }

            let lineBuffer = LockedData()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lastActivity.touch()
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

            if let idleTimeout {
                // Inactivity watchdog: re-arm until the process has been silent for `idleTimeout`.
                func checkIdle() {
                    DispatchQueue.global().asyncAfter(deadline: .now() + idleTimeout) {
                        guard process.isRunning else { return }
                        if lastActivity.secondsSinceLast() >= idleTimeout {
                            process.terminate()
                            continuation.finish(throwing: CLIProcessError.timedOut)
                        } else {
                            checkIdle()
                        }
                    }
                }
                checkIdle()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        process.terminate()
                        continuation.finish(throwing: CLIProcessError.timedOut)
                    }
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

/// Thread-safe monotonic timestamp for the inactivity watchdog.
private final class LockedTimestamp: @unchecked Sendable {
    private let lock = NSLock()
    private var last = DispatchTime.now()
    func touch() { lock.lock(); last = DispatchTime.now(); lock.unlock() }
    func secondsSinceLast() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000_000
    }
}
