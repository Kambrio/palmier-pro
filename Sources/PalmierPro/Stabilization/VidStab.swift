import Foundation

/// Detects whether a vid.stab-capable ffmpeg is available (the engine requires it).
enum VidStab {
    /// Cached availability: ffmpeg on PATH whose filter list includes `vidstabtransform`.
    static let isAvailable: Bool = {
        guard let ffmpeg = CLILocator.loginShellWhich("ffmpeg") else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("vidstabtransform")
    }()
}
