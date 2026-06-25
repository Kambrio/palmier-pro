import Foundation

/// Target proxy resolution, by short side. Aspect preserved; never upscaled.
enum ProxyResolution: String, CaseIterable, Sendable, Codable {
    case p240, p360, p480, p720, p1080

    var shortSide: Int {
        switch self {
        case .p240: 240
        case .p360: 360
        case .p480: 480
        case .p720: 720
        case .p1080: 1080
        }
    }

    var label: String { "\(shortSide)p" }

    /// Scales to `shortSide` on the short side; aspect-preserving, even, never upscaled.
    func targetSize(forSource source: CGSize) -> CGSize {
        let w = source.width, h = source.height
        guard w > 0, h > 0 else { return source }
        let srcShort = min(w, h)
        let scale = min(1.0, Double(shortSide) / Double(srcShort))
        func even(_ v: Double) -> Int { let i = Int(v.rounded()); return max(2, i - (i % 2)) }
        return CGSize(width: even(Double(w) * scale), height: even(Double(h) * scale))
    }
}
