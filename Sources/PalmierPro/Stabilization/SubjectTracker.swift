import AVFoundation
import Vision

enum SubjectTracker {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// One StabFrameTransform per source frame with tx=subjectCenterX, ty=subjectCenterY
    /// (normalized, top-left origin). Throws if no subject is ever detected.
    static func track(
        input: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (fps: Double, frames: [StabFrameTransform]) {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(reason: "no video track")
        }
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let estTotal = max(1, Int((duration * max(1, fps)).rounded()))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure(reason: "reader failed") }

        var frames: [StabFrameTransform] = []
        var seq = VNSequenceRequestHandler()
        var lastObservation: VNDetectedObjectObservation?
        var lastCenter = CGPoint(x: 0.5, y: 0.5)
        var everDetected = false
        var count = 0

        while true {
            try Task.checkCancellation()
            let finished = autoreleasepool { () -> Bool in
                guard let sample = output.copyNextSampleBuffer(),
                      let buffer = CMSampleBufferGetImageBuffer(sample) else { return true }
                count += 1
                var box: CGRect? = nil
                // Track existing observation; re-detect on loss or low confidence.
                if let obs = lastObservation {
                    let req = VNTrackObjectRequest(detectedObjectObservation: obs)
                    req.trackingLevel = .accurate
                    if (try? seq.perform([req], on: buffer)) != nil,
                       let r = req.results?.first as? VNDetectedObjectObservation,
                       r.confidence > 0.3 {
                        box = r.boundingBox
                        lastObservation = r
                    } else {
                        lastObservation = nil
                    }
                }
                if box == nil {
                    if let b = detectSubject(buffer) {
                        box = b
                        lastObservation = VNDetectedObjectObservation(boundingBox: b)
                        seq = VNSequenceRequestHandler()  // reset sequence on re-seed
                        everDetected = true
                    }
                }
                if let b = box {
                    everDetected = true
                    // Vision boxes: normalized, bottom-left origin → convert to top-left center.
                    lastCenter = CGPoint(x: b.midX, y: 1 - b.midY)
                }
                frames.append(StabFrameTransform(m: [1, 0, Double(lastCenter.x),
                                                     0, 1, Double(lastCenter.y),
                                                     0, 0, 1]))
                if count % 10 == 0 { progress(min(1, Double(count) / Double(estTotal))) }
                return false
            }
            if finished { break }
            if count % 30 == 0 { await Task.yield() }
        }
        guard everDetected, !frames.isEmpty else { throw Failure(reason: "no subject detected") }
        progress(1)
        return (fps == 0 ? 30 : fps, frames)
    }

    /// Largest person box, else largest face box; nil if none detected.
    /// Returned rect is normalized with bottom-left origin (Vision convention).
    private static func detectSubject(_ buffer: CVPixelBuffer) -> CGRect? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        let people = VNDetectHumanRectanglesRequest()
        if (try? handler.perform([people])) != nil,
           let boxes = people.results?.map(\.boundingBox),
           let big = boxes.max(by: { $0.area < $1.area }) {
            return big
        }
        let faces = VNDetectFaceRectanglesRequest()
        if (try? handler.perform([faces])) != nil,
           let boxes = faces.results?.map(\.boundingBox),
           let big = boxes.max(by: { $0.area < $1.area }) {
            return big
        }
        return nil
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
