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

    private let lock = NSLock()
    nonisolated(unsafe) private var model: VNCoreMLModel?

    /// Locate the compiled detector via `Bundle.main` candidate paths — never `Bundle.module`, whose
    /// SwiftPM accessor fatalErrors when the resource bundle is absent (see BundledFonts/ClaudeCLISkills).
    nonisolated private static func detectorURL() throws -> URL {
        // Search bundle roots manually instead of Bundle.module, whose SwiftPM accessor fatalErrors when
        // the resource bundle is absent (see BundledFonts/ClaudeCLISkills). bundle.sh flattens Models/ into
        // Contents/Resources; swift run/tests keep it in PalmierPro_PalmierPro.bundle next to the executable.
        let forClass = Bundle(for: ObjectDetector.self)
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            forClass.resourceURL,
            forClass.bundleURL,
            forClass.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }
        let suffixes = [
            "Models/Detector.mlmodelc",                          // packaged .app
            "PalmierPro_PalmierPro.bundle/Models/Detector.mlmodelc", // swift run / tests
            "Detector.mlmodelc",                                  // flattened fallback
        ]
        for root in roots {
            for suffix in suffixes {
                let url = root.appendingPathComponent(suffix)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        throw Failure(reason: "Detector.mlmodelc not found in app bundle")
    }

    /// Compile + cache the CoreML model; called inside the worker so the first-call compile doesn't hitch main.
    nonisolated private func loadModel() throws -> VNCoreMLModel {
        lock.lock(); defer { lock.unlock() }
        if let model { return model }
        let core = try MLModel(contentsOf: Self.detectorURL())
        let vn = try VNCoreMLModel(for: core)
        model = vn
        return vn
    }

    /// Detect objects in `image`. Inference runs off the main thread. Never throws on zero detections.
    func detect(in image: CGImage) async throws -> [DetectedObject] {
        // Map Vision results to Sendable DetectedObjects inside the worker so nothing non-Sendable crosses back.
        return try await withCheckedThrowingContinuation { cont in
            // Vision inference is CPU/ANE-heavy — keep it (and the model compile) off the main actor.
            // .utility so background footage analysis lands on efficiency cores and never starves the UI.
            DispatchQueue.global(qos: .utility).async { [self] in
                let request: VNCoreMLRequest
                do {
                    request = VNCoreMLRequest(model: try loadModel())
                } catch {
                    cont.resume(throwing: error)
                    return
                }
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
