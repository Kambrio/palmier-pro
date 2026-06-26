import AVFoundation
import Vision
import CoreImage
import simd

enum StabilizationAnalyzer {
    struct Failure: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    /// One ABSOLUTE-cumulative transform per source frame (frames[0] = identity); progress is 0…1.
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
        let handler = VNSequenceRequestHandler()
        let ciContext = CIContext()

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let rawBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let buffer = downscaled(rawBuffer, longEdge: analysisLongEdge, ctx: ciContext)
            defer { previous = buffer }
            count += 1
            guard let prev = previous else { continue }
            let delta = registerDelta(from: prev, to: buffer, handler: handler)
            if (0..<3).allSatisfy({ r in (0..<3).allSatisfy { c in delta[c][r].isFinite } }) {
                accumulated = accumulated * delta
            }
            frames.append(StabFrameTransform(accumulated))
            if count % 10 == 0 { progress(min(1, Double(count) / Double(estTotal))) }
        }
        if reader.status == .failed { throw Failure(reason: reader.error?.localizedDescription ?? "read error") }
        progress(1)
        return (fps == 0 ? 30 : fps, frames)
    }

    private static let analysisLongEdge: CGFloat = 540

    private static func downscaled(_ buffer: CVPixelBuffer, longEdge: CGFloat, ctx: CIContext) -> CVPixelBuffer {
        let w = CGFloat(CVPixelBufferGetWidth(buffer)), h = CGFloat(CVPixelBufferGetHeight(buffer))
        let longer = max(w, h)
        guard longer > longEdge else { return buffer }
        let s = longEdge / longer
        let dstW = Int((w * s).rounded()), dstH = Int((h * s).rounded())
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, dstW, dstH, kCVPixelFormatType_32BGRA, nil, &out)
        guard let dst = out else { return buffer }
        let img = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: s, y: s))
        ctx.render(img, to: dst)
        return dst
    }

    /// Consecutive-frame registration as a normalized homography; homographic with translational fallback.
    private static func registerDelta(from prev: CVPixelBuffer, to curr: CVPixelBuffer, handler: VNSequenceRequestHandler) -> simd_double3x3 {
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: curr)
        do {
            try handler.perform([request], on: prev)
            if let obs = request.results?.first as? VNImageHomographicAlignmentObservation {
                let m = obs.warpTransform   // matrix_float3x3, normalized coords
                let h = simd_double3x3(
                    SIMD3(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
                    SIMD3(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
                    SIMD3(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)))
                let t = StabFrameTransform(h)
                if t.m.allSatisfy(\.isFinite), abs(h.determinant) > 1e-9 { return t.matrix }
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
