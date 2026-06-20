import Foundation

/// Drives a single chat turn through the Claude Code CLI. The CLI runs the full
/// agentic loop itself, calling Palmier MCP tools that mutate the live editor.
struct ClaudeCLIRunner {
    let claudePath: String
    let model: AnthropicModel
    let systemPrompt: String
    /// Hard cap on the CLI's internal agentic loop so one chat turn can't run away on
    /// the user's Claude quota.
    var maxTurns: Int = 30

    /// CLI model alias for `--model`.
    static func alias(for model: AnthropicModel) -> String {
        switch model {
        case .opus47: "opus"
        case .sonnet46: "sonnet"
        case .haiku45: "haiku"
        }
    }

    /// Streams events for one user turn. `resumeSessionId` continues a prior CLI session.
    /// The stream finishes when the CLI exits; cancelling it terminates the process.
    func stream(
        userText: String,
        resumeSessionId: String?,
        onSessionId: @escaping @Sendable (String) -> Void
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        var args = [
            "-p", userText,
            "--output-format", "stream-json",
            "--verbose",
            "--model", Self.alias(for: model),
            "--max-turns", String(maxTurns),
            "--mcp-config", PalmierMCPConfig.inlineConfigJSON(),
            "--strict-mcp-config",
            "--allowedTools", PalmierMCPConfig.allowedToolsPattern,
            "--append-system-prompt", systemPrompt,
        ]
        if let resumeSessionId {
            args.append(contentsOf: ["--resume", resumeSessionId])
        }

        let proc = CLIProcess(executable: claudePath, arguments: args)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = ClaudeStreamJSONParser()
                do {
                    for try await line in proc.streamLines() {
                        for event in parser.consume(line: line) { continuation.yield(event) }
                    }
                    if let sid = parser.sessionId { onSessionId(sid) }
                    continuation.finish()
                } catch {
                    if let sid = parser.sessionId { onSessionId(sid) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
