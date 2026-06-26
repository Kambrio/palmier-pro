import Foundation

/// Detects whether a vid.stab-capable ffmpeg is available (the engine requires it).
/// Detection shells out to ffmpeg, so it MUST run off-main — never during a SwiftUI body
/// (a blocking subprocess inside the view update aborts the AttributeGraph).
@MainActor
enum VidStab {
    private static var cached: Bool?

    /// Pure, non-blocking read for views. False until detection resolves (gated UI default).
    static var isAvailable: Bool { cached ?? false }

    /// Kick off detection once, off the main thread; result is cached on main.
    static func detectIfNeeded() {
        guard cached == nil else { return }
        cached = false   // definite default until the probe answers, and de-dupes re-entry
        Task.detached(priority: .utility) {
            let ok = detect()
            await MainActor.run { cached = ok }
        }
    }

    private nonisolated static func detect() -> Bool {
        guard let ffmpeg = CLILocator.loginShellWhich("ffmpeg") else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("vidstabtransform")
    }
}
