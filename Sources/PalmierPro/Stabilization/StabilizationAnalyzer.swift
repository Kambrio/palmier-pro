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
                    let (dtx, dty, drot, dscale) = registerDelta(from: prev, to: buffer)
                    // Clamp per-frame motion to sane handheld bounds; wild values are registration errors.
                    let cdtx = dtx.clamped(to: -0.08...0.08)
                    let cdty = dty.clamped(to: -0.08...0.08)
                    let cdrot = drot.clamped(to: -0.087...0.087)    // ±5°
                    let cdscale = dscale.clamped(to: 0.97...1.03)
                    // Compose the small delta onto the absolute path; clamp absolute accumulators
                    // so monotonic drift can never push them toward infinity → NaN in similarityTransform.
                    accTx = (accTx + cdtx).clamped(to: -50...50)
                    accTy = (accTy + cdty).clamped(to: -50...50)
                    accRot = (accRot + cdrot).clamped(to: -50...50)
                    accScale = (accScale * cdscale).clamped(to: 0.1...10.0)
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

    private static let analysisLongEdge: CGFloat = 720

    // Perspective terms are intentionally dropped: accumulating them over many frames diverges. All methods share this bounded similarity path; .perspective currently renders equivalently to .similarity.
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

    /// Per-frame motion as normalized (tx, ty, rotation, scale). Vision's warpTransform translation
    /// is in ANALYSIS-FRAME PIXELS, so it MUST be divided by frame dimensions — the original bug was
    /// using it as if already normalized, making a few-pixel shift read as several frame-widths.
    /// Validated cascade: plausible homography → plausible translation → identity (reject garbage).
    private static func registerDelta(from prev: CVPixelBuffer, to curr: CVPixelBuffer)
        -> (tx: Double, ty: Double, rot: Double, scale: Double) {
        let w = Double(CVPixelBufferGetWidth(curr)), h = Double(CVPixelBufferGetHeight(curr))
        let handler = VNSequenceRequestHandler()

        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: curr)
        if (try? handler.perform([request], on: prev)) != nil,
           let obs = request.results?.first as? VNImageHomographicAlignmentObservation {
            let m = obs.warpTransform
            let a = Double(m.columns.0.x), c = Double(m.columns.0.y)
            let b = Double(m.columns.1.x), d = Double(m.columns.1.y)
            let tx = Double(m.columns.2.x) / max(1, w)   // pixels → normalized
            let ty = Double(m.columns.2.y) / max(1, h)
            let scale = (hypot(a, c) + hypot(b, d)) / 2
            let rot = atan2(c, a)
            // Accept only physically plausible single-frame motion; else fall through.
            if [tx, ty, rot, scale].allSatisfy(\.isFinite),
               abs(tx) < 0.2, abs(ty) < 0.2, abs(rot) < 0.2, scale > 0.8, scale < 1.25 {
                return (tx, ty, rot, scale)
            }
        }

        let treq = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: curr)
        if (try? handler.perform([treq], on: prev)) != nil,
           let obs = treq.results?.first as? VNImageTranslationAlignmentObservation {
            let a = obs.alignmentTransform
            let tx = Double(a.tx) / max(1, w), ty = Double(a.ty) / max(1, h)
            if tx.isFinite, ty.isFinite, abs(tx) < 0.2, abs(ty) < 0.2 {
                return (tx, ty, 0, 1)
            }
        }
        return (0, 0, 0, 1)   // registration failed/implausible → assume no motion this frame
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}
