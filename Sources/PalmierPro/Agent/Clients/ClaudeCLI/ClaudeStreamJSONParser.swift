import Foundation

/// Incremental parser for `claude --output-format stream-json` lines.
/// Stateless except for the captured session id.
struct ClaudeStreamJSONParser {
    private(set) var sessionId: String?

    mutating func consume(line: String) -> [AnthropicStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        if let sid = obj["session_id"] as? String { sessionId = sid }

        switch type {
        case "assistant":
            return assistantEvents(obj)
        case "result":
            return [.messageStop(stopReason: .endTurn)]
        default:
            return []
        }
    }

    private func assistantEvents(_ obj: [String: Any]) -> [AnthropicStreamEvent] {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        var events: [AnthropicStreamEvent] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    events.append(.textDelta(text))
                }
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                let json = (try? JSONSerialization.data(withJSONObject: input))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                events.append(.toolUseComplete(id: id, name: name, inputJSON: json))
            default:
                break
            }
        }
        return events
    }
}
