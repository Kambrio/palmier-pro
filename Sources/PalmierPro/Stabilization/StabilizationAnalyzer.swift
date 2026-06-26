import AVFoundation
import Vision
import CoreImage
import simd

enum StabilizationAnalyzer {
    struct Failure: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    /// Returns one ABSOLUTE-cumulative transform per source frame; element 0 is identity.
    /// `progress` is 0…1. Throws CancellationError if the surrounding Task is cancelled.
    static func analyze(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (fps: Double, frames: [StabFrameTransform]) {
        let asset = AVURLAsset(url: url)
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
        guard reader.startReading() else { throw Failure(reason: "reader failed to start") }

        var frames: [StabFrameTransform] = [.identity]
        var accumulated = matrix_identity_double3x3
        var previous: CVPixelBuffer?
        var count = 0

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            defer { previous = buffer }
            count += 1
            guard let prev = previous else { continue }
            let delta = registerDelta(from: prev, to: buffer)
            accumulated = accumulated * delta
            frames.append(StabFrameTransform(accumulated))
            if count % 10 == 0 { progress(min(1, Double(count) / Double(estTotal))) }
        }
        if reader.status == .failed { throw Failure(reason: reader.error?.localizedDescription ?? "read error") }
        progress(1)
        return (fps == 0 ? 30 : fps, frames)
    }

    /// Consecutive-frame registration as a normalized homography; homographic with translational fallback.
    private static func registerDelta(from prev: CVPixelBuffer, to curr: CVPixelBuffer) -> simd_double3x3 {
        let handler = VNSequenceRequestHandler()
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: curr)
        do {
            try handler.perform([request], on: prev)
            if let obs = request.results?.first as? VNImageHomographicAlignmentObservation {
                let m = obs.warpTransform   // matrix_float3x3, normalized coords
                let h = simd_double3x3(
                    SIMD3(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
                    SIMD3(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
                    SIMD3(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)))
                if h.columns.0.x.isFinite, h.columns.2.x.isFinite, h.determinant != 0 { return h }
            }
        } catch { /* fall through to translational */ }

        let treq = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: curr)
        if (try? handler.perform([treq], on: prev)) != nil,
           let obs = treq.results?.first as? VNImageTranslationAlignmentObservation {
            let a = obs.alignmentTransform
            let w = Double(CVPixelBufferGetWidth(curr)), hgt = Double(CVPixelBufferGetHeight(curr))
            // Translation normalized to [0,1] coords; stored in column 2 so m[2] = tx_norm.
            return simd_double3x3(
                SIMD3(1, 0, 0),
                SIMD3(0, 1, 0),
                SIMD3(Double(a.tx) / max(1, w), Double(a.ty) / max(1, hgt), 1))
        }
        return matrix_identity_double3x3
    }
}
