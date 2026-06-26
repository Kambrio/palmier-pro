import Foundation

/// Detects the available ffmpeg stabilization capability. Probe runs off-main (a subprocess in a
/// SwiftUI body aborts the AttributeGraph), result cached for pure main-thread reads.
@MainActor
enum VidStab {
    enum Capability { case none, deshake, vidstab }   // none = no ffmpeg

    private static var cached: Capability?

    /// True if ANY ffmpeg stabilization is usable (deshake is built into stock ffmpeg).
    static var isAvailable: Bool { (cached ?? .none) != .none }
    /// The capability the engine will use (vidstab preferred, else deshake).
    static var capability: Capability { cached ?? .none }

    /// Kick off detection once, off the main thread; result is cached on main.
    static func detectIfNeeded() {
        guard cached == nil else { return }
        cached = .none as Capability   // definite default until the probe answers, and de-dupes re-entry
        Task.detached(priority: .utility) {
            let cap = detect()
            await MainActor.run { cached = cap }
        }
    }

    private nonisolated static func detect() -> Capability {
        guard let ffmpeg = CLILocator.loginShellWhich("ffmpeg") else { return .none }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        do { try proc.run() } catch { return .none }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        if out.contains("vidstabtransform") { return .vidstab }
        if out.contains("deshake") { return .deshake }
        return .none
    }

    /// Located ffmpeg path (nil if none). For the generation service.
    nonisolated static func ffmpegPath() -> String? { CLILocator.loginShellWhich("ffmpeg") }
}
