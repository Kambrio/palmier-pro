import Foundation

/// Wires the Palmier MCP server into the Claude CLI two ways:
/// 1. An inline --mcp-config JSON used by the app's own `claude -p` invocations (scoped,
///    no permission prompts, always correct port).
/// 2. A one-time `claude mcp add` so the user's interactive terminal also sees Palmier.
enum PalmierMCPConfig {

    static var endpoint: String { "http://127.0.0.1:\(MCPService.port)/mcp" }

    static let serverName = "palmier-pro"

    /// Tool allowlist pattern that pre-authorizes every Palmier MCP tool in -p mode.
    static let allowedToolsPattern = "mcp__palmier-pro__*"

    /// JSON string for `--mcp-config`.
    static func inlineConfigJSON() -> String {
        let dict: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "type": "http",
                    "url": endpoint,
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static let registeredKey = "io.palmier.pro.chat.cli.mcpRegistered"

    /// Idempotently runs `claude mcp add …`. Non-fatal on failure.
    static func registerIfNeeded(claudePath: String) async {
        guard !UserDefaults.standard.bool(forKey: registeredKey) else { return }
        let proc = CLIProcess(
            executable: claudePath,
            arguments: ["mcp", "add", "--transport", "http", serverName, endpoint],
            timeout: 30
        )
        do {
            _ = try await proc.runCapturing()
            UserDefaults.standard.set(true, forKey: registeredKey)
            Log.mcp.notice("registered palmier-pro MCP with claude CLI")
        } catch {
            // Already-exists or transient failure — the inline config covers our own calls.
            Log.mcp.notice("claude mcp add skipped: \(error.localizedDescription)")
        }
    }
}
