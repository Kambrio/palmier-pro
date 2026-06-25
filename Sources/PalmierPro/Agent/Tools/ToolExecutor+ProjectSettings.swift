import Foundation

extension ToolExecutor {
    private static let setProjectSettingsAllowedKeys: Set<String> = ["width", "height", "fps"]

    func setProjectSettings(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.setProjectSettingsAllowedKeys, path: "set_project_settings")

        let newWidth = args.int("width")
        let newHeight = args.int("height")
        let newFPS = args.int("fps")
        guard newWidth != nil || newHeight != nil || newFPS != nil else {
            throw ToolError("Provide at least one of 'width', 'height', or 'fps'")
        }

        let width = newWidth ?? editor.timeline.width
        let height = newHeight ?? editor.timeline.height
        let fps = newFPS ?? editor.timeline.fps

        guard (16...8192).contains(width), (16...8192).contains(height) else {
            throw ToolError("width and height must be 16–8192 (got \(width)×\(height))")
        }
        guard width % 2 == 0, height % 2 == 0 else {
            throw ToolError("width and height must be even — video encoders require even dimensions (got \(width)×\(height))")
        }
        guard (1...240).contains(fps) else {
            throw ToolError("fps must be 1–240 (got \(fps))")
        }

        editor.applyTimelineSettings(fps: fps, width: width, height: height)

        let fpsNote = newFPS != nil ? " FPS change rescaled all clip timing." : ""
        return .ok("Project settings set to \(width)×\(height) @ \(fps)fps. Auto-fitted clips were refit to the new canvas.\(fpsNote)")
    }
}
