import Foundation

/// One parsed line of the worker's stdout. `nil` = not JSON (ignore); `.other` =
/// a valid status line we don't act on (e.g. job_start).
enum OmniVoiceProgress: Equatable, Sendable {
    case modelReady(device: String)
    case segmentDone(index: Int, durationSeconds: Double)
    case segmentCached(index: Int, durationSeconds: Double)
    case segmentError(index: Int, message: String)
    case complete(total: Int)
    case other

    static func parse(_ line: String) -> OmniVoiceProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let status = obj["status"] as? String
        if let seg = obj["segment"] as? Int {
            switch status {
            case "done":
                return .segmentDone(index: seg, durationSeconds: obj["actual_duration"] as? Double ?? 0)
            case "cached":
                return .segmentCached(index: seg, durationSeconds: obj["actual_duration"] as? Double ?? 0)
            case "error":
                return .segmentError(index: seg, message: obj["error"] as? String ?? "unknown error")
            default:
                return .other
            }
        }
        switch status {
        case "model_ready": return .modelReady(device: obj["device"] as? String ?? "cpu")
        case "complete":    return .complete(total: obj["total"] as? Int ?? 0)
        default:            return .other
        }
    }
}
