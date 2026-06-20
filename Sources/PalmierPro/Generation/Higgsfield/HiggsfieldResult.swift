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
    /// Extracts result URLs from `--json` output. Tolerates several shapes.
    static func resultURLs(fromJSON json: String) throws -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw HiggsfieldResultError.noURL(json)
        }

        if let dict = obj as? [String: Any] {
            if let single = dict["cdn_url"] as? String { return [single] }
            if let urls = dict["urls"] as? [String], !urls.isEmpty { return urls }
            if let results = dict["results"] as? [[String: Any]] {
                let urls = results.compactMap { $0["url"] as? String ?? $0["cdn_url"] as? String }
                if !urls.isEmpty { return urls }
            }
            if let url = dict["url"] as? String { return [url] }
        }
        throw HiggsfieldResultError.noURL(json)
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
