import Foundation

/// Resolves an absolute path to a CLI tool. A GUI app launched from Finder has a
/// minimal PATH, so we probe common install dirs and fall back to a login shell.
struct CLILocator: Sendable {
    let tool: String
    let searchDirs: [String]
    let shellResolver: @Sendable () -> String?

    static let defaultSearchDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.claude/local",
    ]

    init(tool: String,
         searchDirs: [String] = CLILocator.defaultSearchDirs,
         shellResolver: (@Sendable () -> String?)? = nil) {
        self.tool = tool
        self.searchDirs = searchDirs
        self.shellResolver = shellResolver ?? { CLILocator.loginShellWhich(tool) }
    }

    /// Returns the first usable absolute path, or nil.
    func resolve(override: String?) -> String? {
        if let override, isExecutable(override) { return override }
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if isExecutable(candidate) { return candidate }
        }
        // `command -v` only prints runnable commands, so trust the shell result.
        if let viaShell = shellResolver() { return viaShell }
        return nil
    }

    private func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    static func loginShellWhich(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}
