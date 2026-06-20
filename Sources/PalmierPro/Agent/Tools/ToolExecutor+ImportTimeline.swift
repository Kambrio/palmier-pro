import Foundation

extension ToolExecutor {
    private static let importTimelineAllowedKeys: Set<String> = ["path"]

    func importTimeline(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.importTimelineAllowedKeys, path: "import_timeline")
        guard let path = args.string("path"), !path.isEmpty else {
            throw ToolError("Missing required 'path'")
        }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "fcpxml" else {
            throw ToolError("Only .fcpxml files are supported (got '.\(url.pathExtension)')")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("File not found: \(path)")
        }
        do {
            let summary = try FCPXMLImporter.importFile(at: url, into: editor)
            guard summary.clipsAdded > 0 else {
                return .error("No importable clips found in \(url.lastPathComponent).")
            }
            return .ok(summary.text + " See get_timeline / get_media for the result.")
        } catch {
            return .error("FCPXML import failed: \(error.localizedDescription)")
        }
    }
}
