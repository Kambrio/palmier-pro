import CoreGraphics
import CoreML
import Foundation
@preconcurrency import Vision

/// One detected object from the bundled YOLO detector.
struct DetectedObject: Identifiable, Sendable, Equatable {
    let id: Int            // index in the result set
    let label: String      // e.g. "person"
    let confidence: Float
    let box: CGRect        // normalized, TOP-LEFT origin (converted from Vision bottom-left)
}

/// Runs the bundled YOLO11n Core ML detector to produce clickable labeled boxes.
@MainActor
final class ObjectDetector {
    static let shared = ObjectDetector()

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private var model: VNCoreMLModel?

    private func loadModel() throws -> VNCoreMLModel {
        if let model { return model }
        let url = Bundle.module.url(forResource: "Models/Detector", withExtension: "mlmodelc")
            // Resources get flattened in the bundled .app — fall back to the root path.
            ?? Bundle.module.url(forResource: "Detector", withExtension: "mlmodelc")
        guard let url else { throw Failure(reason: "Detector.mlmodelc not found in bundle") }
        let core = try MLModel(contentsOf: url)
        let vn = try VNCoreMLModel(for: core)
        model = vn
        return vn
    }

    /// Detect objects in `image`. Inference runs off the main thread. Never throws on zero detections.
    func detect(in image: CGImage) async throws -> [DetectedObject] {
        let model = try loadModel()
        // Map Vision results to Sendable DetectedObjects inside the worker so nothing non-Sendable crosses back.
        return try await withCheckedThrowingContinuation { cont in
            // Vision inference is CPU/ANE-heavy — keep it off the main actor.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNCoreMLRequest(model: model)
                request.imageCropAndScaleOption = .scaleFill
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results as? [VNRecognizedObjectObservation] ?? []
                    let objects = observations
                        .filter { $0.confidence >= 0.25 }
                        .sorted { $0.confidence > $1.confidence }
                        .prefix(20)
                        .enumerated()
                        .map { idx, obs -> DetectedObject in
                            let v = obs.boundingBox  // normalized, bottom-left
                            let topLeft = CGRect(
                                x: v.minX, y: 1 - v.minY - v.height, width: v.width, height: v.height)
                            return DetectedObject(
                                id: idx,
                                label: obs.labels.first?.identifier ?? "object",
                                confidence: obs.confidence,
                                box: topLeft)
                        }
                    cont.resume(returning: objects)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
