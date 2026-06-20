import Foundation
import Testing
@testable import PalmierPro

@Suite("ClaudeCLIRunner argv")
struct ClaudeCLIRunnerArgvTests {

    private func argv(resume: String? = nil) -> [String] {
        ClaudeCLIRunner.argv(userText: "hi", model: .haiku45,
                             systemPrompt: "sys", maxTurns: 30, resumeSessionId: resume)
    }

    @Test func allowsPalmierServerScopeNotGlob() {
        let a = argv()
        // The MCP allow rule is the server scope; the `__*` glob does NOT match MCP tools.
        #expect(adjacent(a, "--allowedTools", "mcp__palmier-pro"))
        #expect(!a.contains("mcp__palmier-pro__*"))
    }

    @Test func disallowsBuiltinFilesystemAndExecTools() {
        let a = argv()
        guard let i = a.firstIndex(of: "--disallowedTools"), i + 1 < a.count else {
            Issue.record("missing --disallowedTools"); return
        }
        let value = a[i + 1]
        for tool in ["Bash", "Read", "Write", "Edit", "WebFetch"] {
            #expect(value.contains(tool), "expected \(tool) to be disallowed")
        }
    }

    @Test func includesStreamingModelMaxTurnsAndStrictConfig() {
        let a = argv()
        #expect(adjacent(a, "--model", "haiku"))
        #expect(adjacent(a, "--max-turns", "30"))
        #expect(a.contains("--strict-mcp-config"))
        #expect(adjacent(a, "--output-format", "stream-json"))
    }

    @Test func resumeAppendsSessionId() {
        #expect(adjacent(argv(resume: "sess-1"), "--resume", "sess-1"))
        #expect(!argv(resume: nil).contains("--resume"))
    }

    @Test func replacesSystemPromptInsteadOfAppending() {
        let a = argv()
        // Replace Claude Code's coding-assistant identity, don't append to it.
        #expect(adjacent(a, "--system-prompt", "sys"))
        #expect(!a.contains("--append-system-prompt"))
        #expect(a.contains("--exclude-dynamic-system-prompt-sections"))
    }

    private func adjacent(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        for i in argv.indices where argv[i] == flag {
            if i + 1 < argv.count && argv[i + 1] == value { return true }
        }
        return false
    }
}
