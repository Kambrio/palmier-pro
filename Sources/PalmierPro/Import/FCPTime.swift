import Foundation

/// Parses FCPXML rational time values ("5s", "116/24s", "0s") to seconds and frames.
enum FCPTime {
    /// Seconds for a raw FCPXML time string, or nil if unparseable.
    static func seconds(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        if let slash = s.firstIndex(of: "/") {
            let numStr = String(s[s.startIndex..<slash])
            let denStr = String(s[s.index(after: slash)...])
            guard let num = Double(numStr), let den = Double(denStr), den != 0 else { return nil }
            return num / den
        }
        return Double(s)
    }

    /// Frame count at `fps`, rounded, or nil if the value is unparseable.
    static func frames(_ raw: String, fps: Int) -> Int? {
        guard let sec = seconds(raw) else { return nil }
        return Int((sec * Double(fps)).rounded())
    }
}
