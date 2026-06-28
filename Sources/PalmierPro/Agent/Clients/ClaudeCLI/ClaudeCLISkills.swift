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
    static var bundledSkillsURL: URL? {
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

    // MARK: - Global install (user's own `claude` CLI)

    private static let globalInstallKey = "io.palmier.pro.cliSkills.globalInstall"

    /// Whether app-bundled skills are installed into the user's GLOBAL `~/.claude/skills/`.
    /// Off by default — installing into the user's global Claude config is opt-in (Settings).
    static var globalInstallEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: globalInstallKey) }
        set { UserDefaults.standard.set(newValue, forKey: globalInstallKey) }
    }

    /// Reconcile the on-disk global skills with the preference: install when enabled, remove when not.
    static func syncGlobalInstall() {
        if globalInstallEnabled { installIntoUserGlobalSkills() }
        else { uninstallFromUserGlobalSkills() }
    }

    /// Names of the skills currently bundled (for Settings display).
    static func bundledSkillNames() -> [String] {
        guard let src = bundledSkillsURL,
              let entries = try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Removes the skills WE installed into `~/.claude/skills/` (tracked by the marker), leaving any
    /// the user authored themselves untouched. Best-effort.
    static func uninstallFromUserGlobalSkills() {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: globalMarkerURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let managed = obj["skills"] as? [String] else { return }
        let globalSkills = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
        for name in managed {
            try? fm.removeItem(at: globalSkills.appendingPathComponent(name, isDirectory: true))
        }
        try? fm.removeItem(at: globalMarkerURL)
        Log.mcp.notice("removed Palmier skills from user global ~/.claude/skills")
    }

    /// Marker tracking which skills we installed into the user's global `~/.claude/skills/`
    /// (and the app version that wrote them), so refreshes are idempotent and we never clobber
    /// a skill the user authored themselves.
    private static var globalMarkerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/.palmier-skills.json")
    }

    /// Installs the app-bundled skills into the user's GLOBAL `~/.claude/skills/` so their own
    /// `claude` CLI (outside the app) discovers them — paired with the global MCP registration,
    /// this makes Palmier's skills + tools usable from any terminal. Idempotent, version-gated,
    /// and best-effort: skips any same-named skill the user already owns. Never throws.
    static func installIntoUserGlobalSkills() {
        guard let src = bundledSkillsURL else { return }
        let fm = FileManager.default
        let globalSkills = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

        var managed = Set<String>()
        var installedVersion = ""
        if let data = try? Data(contentsOf: globalMarkerURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            managed = Set((obj["skills"] as? [String]) ?? [])
            installedVersion = (obj["version"] as? String) ?? ""
        }

        let entries = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let skillDirs = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let names = skillDirs.map { $0.lastPathComponent }
        // Up to date and all present → nothing to do.
        if installedVersion == version, Set(names).isSubset(of: managed),
           names.allSatisfy({ fm.fileExists(atPath: globalSkills.appendingPathComponent($0).path) }) { return }

        guard (try? fm.createDirectory(at: globalSkills, withIntermediateDirectories: true)) != nil else { return }
        var newlyManaged = managed
        for dir in skillDirs {
            let name = dir.lastPathComponent
            let dst = globalSkills.appendingPathComponent(name, isDirectory: true)
            // Respect a pre-existing skill the user authored (one we don't already manage).
            if fm.fileExists(atPath: dst.path) && !managed.contains(name) { continue }
            try? fm.removeItem(at: dst)
            do { try fm.copyItem(at: dir, to: dst); newlyManaged.insert(name) }
            catch { Log.mcp.warning("global skill install failed \(name): \(error.localizedDescription)") }
        }
        let marker: [String: Any] = ["version": version, "skills": Array(newlyManaged).sorted()]
        if let data = try? JSONSerialization.data(withJSONObject: marker) {
            try? data.write(to: globalMarkerURL, options: .atomic)
        }
        Log.mcp.notice("installed \(newlyManaged.count) Palmier skills into user global ~/.claude/skills")
    }
}
