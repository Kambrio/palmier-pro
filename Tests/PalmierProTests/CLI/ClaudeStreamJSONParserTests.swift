import Foundation
import Testing
@testable import PalmierPro

@Suite("ClaudeStreamJSONParser")
struct ClaudeStreamJSONParserTests {

    private func events(_ lines: [String]) -> ([AnthropicStreamEvent], String?) {
        var parser = ClaudeStreamJSONParser()
        var out: [AnthropicStreamEvent] = []
        for line in lines { out.append(contentsOf: parser.consume(line: line)) }
        return (out, parser.sessionId)
    }

    @Test func capturesSessionIdFromInit() {
        let (_, sid) = events([
            #"{"type":"system","subtype":"init","session_id":"abc-123"}"#
        ])
        #expect(sid == "abc-123")
    }

    @Test func emitsTextDeltaForAssistantText() {
        let (evts, _) = events([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#
        ])
        guard case .textDelta(let t)? = evts.first else {
            Issue.record("expected textDelta"); return
        }
        #expect(t == "Hello")
    }

    @Test func emitsToolUseComplete() {
        let (evts, _) = events([
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__palmier-pro__add_clips","input":{"x":1}}]}}"#
        ])
        guard case .toolUseComplete(let id, let name, let json)? = evts.first else {
            Issue.record("expected toolUseComplete"); return
        }
        #expect(id == "t1")
        #expect(name == "mcp__palmier-pro__add_clips")
        #expect(json.contains("\"x\""))
    }

    @Test func emitsMessageStopOnResult() {
        let (evts, sid) = events([
            #"{"type":"result","subtype":"success","session_id":"s9","result":"done"}"#
        ])
        guard case .messageStop(let reason)? = evts.last else {
            Issue.record("expected messageStop"); return
        }
        #expect(reason == .endTurn)
        #expect(sid == "s9")
    }

    @Test func ignoresBlankAndNonJSONLines() {
        let (evts, _) = events(["", "not json", "   "])
        #expect(evts.isEmpty)
    }
}
