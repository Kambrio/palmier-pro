import CoreGraphics
import Foundation
@preconcurrency import Vision

/// On-device structured signals for a single frame, from Apple Vision (zero-download).
struct FrameVisionResult: Sendable {
    var sceneLabels: [String] = []
    var faceCount: Int = 0
    /// Area fraction of the largest detected face (0 if none).
    var largestFaceFraction: Double = 0
    var faceQuality: Double?
    /// Vision feature print of the largest face crop, for identity grouping.
    var faceEmbedding: [Float]?
}

/// Wraps the Apple Vision requests used to understand a footage frame: scene classification,
/// face detection + capture quality, and a face feature print for identity grouping.
enum FrameVisionAnalyzer {
    private static let minSceneConfidence: Float = 0.20
    private static let maxSceneLabels = 6

    static func analyze(_ image: CGImage) async -> FrameVisionResult {
        await withCheckedContinuation { cont in
            // .utility → efficiency cores: background footage analysis must not starve the editor UI.
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: run(image))
            }
        }
    }

    private static func run(_ image: CGImage) -> FrameVisionResult {
        var result = FrameVisionResult()

        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let quality = VNDetectFaceCaptureQualityRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([classify, faces, quality])

        if let observations = classify.results {
            result.sceneLabels = observations
                .filter { $0.confidence >= minSceneConfidence }
                .sorted { $0.confidence > $1.confidence }
                .prefix(maxSceneLabels)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        }

        let faceObs = faces.results ?? []
        result.faceCount = faceObs.count
        if let largest = faceObs.max(by: { $0.boundingBox.area < $1.boundingBox.area }) {
            result.largestFaceFraction = Double(largest.boundingBox.area)
            // Capture-quality observations are independent; match by closest box.
            if let q = quality.results?
                .min(by: { abs($0.boundingBox.area - largest.boundingBox.area) < abs($1.boundingBox.area - largest.boundingBox.area) })?
                .faceCaptureQuality {
                result.faceQuality = Double(q)
            }
            result.faceEmbedding = featurePrint(of: image, faceBox: largest.boundingBox)
        }
        return result
    }

    /// Crops the face region (with padding) and returns its Vision feature print as a float vector.
    private static func featurePrint(of image: CGImage, faceBox: CGRect) -> [Float]? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision boundingBox is normalized, bottom-left. CGImage cropping uses top-left pixels.
        let pad: CGFloat = 0.25
        let bx = max(0, faceBox.minX - faceBox.width * pad)
        let bw = min(1 - bx, faceBox.width * (1 + 2 * pad))
        let byTop = max(0, (1 - faceBox.maxY) - faceBox.height * pad)
        let bh = min(1 - byTop, faceBox.height * (1 + 2 * pad))
        let cropRect = CGRect(x: bx * w, y: byTop * h, width: bw * w, height: bh * h).integral
        guard cropRect.width >= 16, cropRect.height >= 16, let crop = image.cropping(to: cropRect) else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        guard (try? handler.perform([request])) != nil,
              let print = request.results?.first as? VNFeaturePrintObservation else { return nil }
        return Self.vector(from: print)
    }

    private static func vector(from print: VNFeaturePrintObservation) -> [Float]? {
        let count = print.elementCount
        guard count > 0 else { return nil }
        switch print.elementType {
        case .float:
            return print.data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        case .double:
            return print.data.withUnsafeBytes { raw in
                raw.bindMemory(to: Double.self).prefix(count).map { Float($0) }
            }
        default:
            return nil
        }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

/// Compact codec for face feature prints: stored as base64 little-endian Float16 to keep JSON small.
enum EmbeddingCodec {
    static func encode(_ vector: [Float]) -> String {
        var halves = vector.map { Float16($0) }
        let data = halves.withUnsafeBytes { Data($0) }
        return data.base64EncodedString()
    }

    static func decode(_ base64: String?) -> [Float]? {
        guard let base64, let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Float16.self).map { Float($0) }
        }
    }

    /// Cosine similarity in [-1, 1]; nil if either vector is empty or mismatched.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
