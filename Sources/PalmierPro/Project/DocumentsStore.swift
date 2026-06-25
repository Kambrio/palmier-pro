import Foundation

/// User-configurable override for where agent-saved documents go.
enum DocumentPreferences {
    private static let dirKey = "io.palmier.pro.documents.directory"

    /// Custom documents directory, or nil to use the per-project default.
    static var overrideDirectory: URL? {
        get {
            guard let p = UserDefaults.standard.string(forKey: dirKey), !p.isEmpty else { return nil }
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        set {
            if let p = newValue?.path { UserDefaults.standard.set(p, forKey: dirKey) }
            else { UserDefaults.standard.removeObject(forKey: dirKey) }
        }
    }
}

/// Writes agent-produced text artifacts (scripts, hooks, transcript/caption exports, notes)
/// to a controlled, configurable directory — the only sanctioned filesystem write path for
/// the agent. Writes are confined to the base directory (no path traversal).
enum DocumentsStore {
    static let allowedFormats: Set<String> = ["md", "txt", "srt", "vtt"]

    enum DocError: LocalizedError {
        case badFilename(String)
        case unsupportedFormat(String)
        var errorDescription: String? {
            switch self {
            case .badFilename(let n): return "Invalid filename '\(n)': use a plain name with no slashes, '..', or a leading dot."
            case .unsupportedFormat(let f): return "Unsupported format '\(f)'. Use one of: \(DocumentsStore.allowedFormats.sorted().joined(separator: ", "))."
            }
        }
    }

    private static var appDataFallback: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Log.subsystem)/Documents", isDirectory: true)
    }

    /// Resolve the base directory: user override → `<project>/documents` → app-data fallback.
    static func baseDirectory(projectURL: URL?) -> URL {
        if let override = DocumentPreferences.overrideDirectory { return override }
        if let projectURL { return projectURL.appendingPathComponent(Project.documentsDirectoryName, isDirectory: true) }
        return appDataFallback
    }

    /// Collapse a supplied name to a single safe filename component with the right extension.
    static func safeFilename(_ name: String, format: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"), !trimmed.contains("\\"),
              !trimmed.contains(".."), !trimmed.hasPrefix("~"), !trimmed.hasPrefix(".")
        else { throw DocError.badFilename(name) }
        let ext = ".\(format)"
        return trimmed.lowercased().hasSuffix(ext) ? trimmed : trimmed + ext
    }

    @discardableResult
    static func write(_ content: String, filename: String, format: String, projectURL: URL?) throws -> URL {
        guard allowedFormats.contains(format) else { throw DocError.unsupportedFormat(format) }
        let safe = try safeFilename(filename, format: format)
        let dir = baseDirectory(projectURL: projectURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe)
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }
}
