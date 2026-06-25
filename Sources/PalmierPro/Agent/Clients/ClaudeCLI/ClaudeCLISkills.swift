import Foundation

/// Makes the app-bundled creative skills usable by the in-app `claude -p` chat.
///
/// The CLI discovers skills from its working directory's `.claude/skills/`, so the
/// bundled `Resources/Skills` tree is materialized once per launch into a writable
/// workspace (`…/Application Support/PalmierPro/cli-skills/.claude/skills/`). The chat
/// runner sets the child process's cwd to that workspace. Writing to a real dir (not the
/// read-only, code-signed app bundle) avoids translocation/permission issues.
enum ClaudeCLISkills {
    /// Bundled `Skills` resource directory — packaged `.app` or `swift run` layout.
    private static var bundledSkillsURL: URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Skills", isDirectory: true),                                   // packaged .app
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/Contents/Resources/Skills"),       // swift run (macOS bundle)
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/Skills"),                          // swift run (flat)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let workspaceURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/cli-skills", isDirectory: true)

    /// Workspace root containing `.claude/skills/`. Set the chat CLI process cwd to this.
    /// Refreshes the bundled skills into the workspace (cheap — a handful of small files)
    /// so app updates never serve stale skills. Returns nil if none are bundled.
    static func workspaceDirectory() -> URL? {
        guard let src = bundledSkillsURL else {
            Log.mcp.warning("CLI skills: no bundled Skills resource found")
            return nil
        }
        let fm = FileManager.default
        let dst = workspaceURL.appendingPathComponent(".claude/skills", isDirectory: true)
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)   // refresh from the current build's bundle
            try fm.copyItem(at: src, to: dst)
        } catch {
            Log.mcp.warning("CLI skills: failed to materialize workspace: \(error.localizedDescription)")
            return nil
        }
        return workspaceURL
    }
}
