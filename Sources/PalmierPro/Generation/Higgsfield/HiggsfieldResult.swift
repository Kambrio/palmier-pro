import Foundation

enum HiggsfieldResultError: LocalizedError {
    case noURL(String)
    var errorDescription: String? {
        switch self {
        case .noURL(let raw): return "No result URL in Higgsfield output: \(raw.prefix(200))"
        }
    }
}

enum HiggsfieldResult {
    /// Result URL fields the CLI uses, in the job objects it prints. `result_url` is the
    /// real `higgsfield generate create --json` field; the others cover older shapes.
    private static let urlKeys = ["result_url", "cdn_url", "url"]

    /// Extracts result URLs from `higgsfield … --json` output. The output is pretty-printed
    /// (an array of job objects, or one object), possibly with leading progress text; we
    /// locate the JSON and collect every result URL, ignoring input refs under `params`.
    static func resultURLs(fromJSON output: String) throws -> [String] {
        guard let obj = parseJSON(output) else { throw HiggsfieldResultError.noURL(output) }
        var urls: [String] = []
        collectResultURLs(from: obj, into: &urls)
        guard !urls.isEmpty else { throw HiggsfieldResultError.noURL(output) }
        return urls
    }

    /// Parses the whole string as JSON, or from the first `[`/`{` if there's leading text.
    private static func parseJSON(_ s: String) -> Any? {
        if let d = s.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) { return o }
        guard let start = s.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }
        let sub = String(s[start...])
        guard let d = sub.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return o
    }

    /// Collects result URLs anywhere in the JSON, skipping `params` (which holds input refs).
    private static func collectResultURLs(from obj: Any, into urls: inout [String]) {
        if let dict = obj as? [String: Any] {
            for key in urlKeys {
                if let s = dict[key] as? String, s.hasPrefix("http") { urls.append(s) }
            }
            for (k, v) in dict where k != "params" {
                collectResultURLs(from: v, into: &urls)
            }
        } else if let arr = obj as? [Any] {
            for v in arr { collectResultURLs(from: v, into: &urls) }
        }
    }

    private static let resizeSuffix = try! NSRegularExpression(pattern: #"/([0-9a-f]+)_resize\.jpg$"#)

    /// True if the CDN URL is one of the input references (the recurring Higgsfield bug).
    static func isInputReference(_ cdnURL: String, inputUUIDs: [String]) -> Bool {
        let range = NSRange(cdnURL.startIndex..., in: cdnURL)
        guard let match = resizeSuffix.firstMatch(in: cdnURL, range: range),
              let r = Range(match.range(at: 1), in: cdnURL) else { return false }
        return inputUUIDs.contains(String(cdnURL[r]))
    }
}
