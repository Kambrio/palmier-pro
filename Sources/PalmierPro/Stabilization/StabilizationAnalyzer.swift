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
        // Absolute camera path as a bounded similarity (perspective terms cause multiplicative
        // blow-up when accumulated over thousands of frames, so we constrain to similarity).
        var accTx = 0.0, accTy = 0.0, accRot = 0.0, accScale = 1.0
        var previous: CVPixelBuffer?
        var count = 0
        let ciContext = CIContext()

        // Each iteration holds a full-resolution decoded buffer (tens of MB) plus Vision/Core
        // Image scratch; without draining per frame the whole clip's buffers pile up → OOM.
        while true {
            try Task.checkCancellation()
            let finished = autoreleasepool { () -> Bool in
                guard let sample = output.copyNextSampleBuffer(),
                      let rawBuffer = CMSampleBufferGetImageBuffer(sample) else { return true }
                let buffer = downscaled(rawBuffer, longEdge: analysisLongEdge, ctx: ciContext)
                count += 1
                if let prev = previous {
                    let delta = registerDelta(from: prev, to: buffer)
                    if (0..<3).allSatisfy({ r in (0..<3).allSatisfy { c in delta[c][r].isFinite } }) {
                        let (dtx, dty, drot, dscale) = decomposeDelta(delta)
                        // Clamp per-frame motion to sane handheld bounds; wild values are registration errors.
                        let cdtx = dtx.clamped(to: -0.08...0.08)
                        let cdty = dty.clamped(to: -0.08...0.08)
                        let cdrot = drot.clamped(to: -0.087...0.087)    // ±5°
                        let cdscale = dscale.clamped(to: 0.97...1.03)
                        // Compose the small delta onto the absolute path.
                        accTx += cdtx
                        accTy += cdty
                        accRot += cdrot
                        accScale *= cdscale
                    }
                    frames.append(similarityTransform(tx: accTx, ty: accTy, rot: accRot, scale: accScale))
                }
                previous = buffer
                if count % 10 == 0 { progress(min(1, Double(count) / Double(estTotal))) }
                return false
            }
            if finished { break }
            if count % 30 == 0 { await Task.yield() }
        }
        if reader.status == .failed { throw Failure(reason: reader.error?.localizedDescription ?? "read error") }
        progress(1)
        return (fps == 0 ? 30 : fps, frames)
    }

    private static let analysisLongEdge: CGFloat = 540

    /// Decompose a normalized delta homography to (tx, ty, rotation, uniform-scale).
    private static func decomposeDelta(_ h: simd_double3x3) -> (tx: Double, ty: Double, rot: Double, scale: Double) {
        // simd_double3x3 is column-major: h[col][row]. So:
        //   a=h[0][0], c=h[0][1], b=h[1][0], d=h[1][1], tx=h[2][0], ty=h[2][1]
        let a = h[0][0], b = h[1][0], c = h[0][1], d = h[1][1]
        let tx = h[2][0], ty = h[2][1]
        let scale = (hypot(a, c) + hypot(b, d)) / 2
        let rot = atan2(c, a)
        return (tx, ty, rot, scale.isFinite && scale > 0 ? scale : 1)
    }

    /// Build a clean similarity StabFrameTransform (m[8]=1, no perspective) about frame center (0.5,0.5).
    private static func similarityTransform(tx: Double, ty: Double, rot: Double, scale: Double) -> StabFrameTransform {
        let cs = cos(rot) * scale, sn = sin(rot) * scale
        let cx = 0.5, cy = 0.5
        let ex = tx + cx - (cs * cx - sn * cy)
        let ey = ty + cy - (sn * cx + cs * cy)
        return StabFrameTransform(m: [cs, -sn, ex, sn, cs, ey, 0, 0, 1])
    }

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
    private static func registerDelta(from prev: CVPixelBuffer, to curr: CVPixelBuffer) -> simd_double3x3 {
        // Transient per pair: a long-lived sequence handler accumulates state across the whole clip.
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

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}
