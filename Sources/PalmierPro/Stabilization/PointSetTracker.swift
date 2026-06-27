import AVFoundation
import Vision

/// Tracks N user-placed points as small patches and fits the object's per-frame 2D similarity
/// (translation + rotation + uniform scale) from the moving point cloud. Mirrors `SubjectTracker`'s
/// forward+backward, downscale, orientation, and OOM discipline.
enum PointSetTracker {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Cap on buffered backward frames (proxy-res CVPixelBuffers). Beyond it, earlier frames hold the
    /// seed transform constant.
    static let maxBackwardFrames = 900

    /// Closed-form 2D similarity fit P→Q (matched indices). Returns `a = s·cosθ`, `b = s·sinθ`, and
    /// the current centroid `μQ`. ≥2 points → full fit; 1 point → translation only; 0 → nil.
    /// Rejects outliers (residual > 2.5× median) once when there are > 2 points.
    /// `aspect = outH/outW`: the fit runs in pixel-proportional space (y scaled by aspect) so a real
    /// pixel-space rotation stays a true similarity on non-square frames; the centroid stays normalized.
    static func fitSimilarity(reference P: [CGPoint], current Q: [CGPoint], aspect: Double = 1)
        -> (a: Double, b: Double, centroid: CGPoint)? {
        guard P.count == Q.count else { return nil }
        return fit(P, Q, aspect: aspect, rejectOutliers: true)
    }

    private static func mean(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let n = Double(pts.count)
        let sx = pts.reduce(0.0) { $0 + Double($1.x) }
        let sy = pts.reduce(0.0) { $0 + Double($1.y) }
        return CGPoint(x: sx / n, y: sy / n)
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    private static func fit(_ P: [CGPoint], _ Q: [CGPoint], aspect: Double, rejectOutliers: Bool)
        -> (a: Double, b: Double, centroid: CGPoint)? {
        let n = P.count
        guard n >= 1 else { return nil }
        let muQ = mean(Q)            // normalized centroid, returned as-is
        if n == 1 { return (1, 0, muQ) }
        let muP = mean(P)
        // Accumulate in pixel-proportional space: y scaled by aspect (x by 1). a,b are dimensionless.
        var den = 0.0, sa = 0.0, sb = 0.0
        for i in 0..<n {
            let px = Double(P[i].x - muP.x), py = Double(P[i].y - muP.y) * aspect
            let qx = Double(Q[i].x - muQ.x), qy = Double(Q[i].y - muQ.y) * aspect
            den += px * px + py * py
            sa += px * qx + py * qy
            sb += px * qy - py * qx
        }
        let eps = 1e-12
        guard den > eps else { return (1, 0, muQ) }   // coincident reference → translation only
        var a = sa / den, b = sb / den

        if rejectOutliers, n > 2 {
            var residuals = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let px = Double(P[i].x - muP.x), py = Double(P[i].y - muP.y) * aspect
                let qx = Double(Q[i].x - muQ.x), qy = Double(Q[i].y - muQ.y) * aspect
                residuals[i] = hypot(a * px - b * py - qx, b * px + a * py - qy)
            }
            let med = median(residuals)
            if med > eps {
                let keep = (0..<n).filter { residuals[$0] <= 2.5 * med }
                if keep.count >= 2, keep.count < n {
                    return fit(keep.map { P[$0] }, keep.map { Q[$0] }, aspect: aspect, rejectOutliers: false)
                }
            }
        }

        let s = hypot(a, b)
        if s.isFinite, s > 0 {
            let clamped = min(max(s, 0.2), 5)
            if clamped != s { let f = clamped / s; a *= f; b *= f }
        } else {
            a = 1; b = 0
        }
        guard a.isFinite, b.isFinite else { return (1, 0, muQ) }
        return (a, b, muQ)
    }

    /// Encode a similarity fit as `[a,-b,cx, b,a,cy, 0,0,1]` (decomposes correctly in PathSmoother).
    /// Anchors the emitted centroid to the image of the FULL seed centroid under the fit, so losing a
    /// tracked point doesn't pop the path: `pos = μQ_subset + M·(μP_full − μP_subset)` (pixel space).
    private static func transform(
        from centers: [CGPoint?], reference P: [CGPoint], last: StabFrameTransform, aspect: Double
    ) -> StabFrameTransform {
        var rp: [CGPoint] = [], cq: [CGPoint] = []
        for i in centers.indices where centers[i] != nil { rp.append(P[i]); cq.append(centers[i]!) }
        guard let f = fitSimilarity(reference: rp, current: cq, aspect: aspect) else { return last }
        let a = f.a, b = f.b
        let dPx = Double(mean(P).x - mean(rp).x), dPy = Double(mean(P).y - mean(rp).y)
        let cx = Double(f.centroid.x) + a * dPx - b * dPy * aspect
        let cy = Double(f.centroid.y) + b * dPx / aspect + a * dPy
        return StabFrameTransform(m: [a, -b, cx, b, a, cy, 0, 0, 1])
    }

    /// Track a user-placed point set from `seedFrame` both forward (to end) and backward (to 0).
    /// `seedPointsTopLeft` are normalized, TOP-LEFT. Output is one similarity transform per source frame.
    static func track(
        input: URL,
        seedFrame: Int,
        seedPointsTopLeft: [CGPoint],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (fps: Double, frames: [StabFrameTransform]) {
        guard !seedPointsTopLeft.isEmpty else { throw Failure(reason: "no seed points") }
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(reason: "no video track")
        }
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let estTotal = max(1, Int((duration * max(1, fps)).rounded()))
        let (outW, outH) = downscaledDims(try await track.load(.naturalSize))
        let aspect = Double(outH) / Double(outW)   // fit in pixel-proportional space
        let orientation = orientation(from: try await track.load(.preferredTransform))

        // Square patch ~6% of the min frame dimension; normalized w/h differ on non-square frames.
        let patchPx = 0.06 * Double(min(outW, outH))
        let pw = patchPx / Double(outW), ph = patchPx / Double(outH)
        func visionBox(_ tl: CGPoint) -> CGRect {
            CGRect(x: Double(tl.x) - pw / 2, y: (1 - Double(tl.y)) - ph / 2, width: pw, height: ph)
        }
        let seedObservations: [VNDetectedObjectObservation] =
            seedPointsTopLeft.map { VNDetectedObjectObservation(boundingBox: visionBox($0)) }
        let seedTransform = transform(
            from: seedPointsTopLeft.map { Optional($0) }, reference: seedPointsTopLeft,
            last: .identity, aspect: aspect)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH,
            ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure(reason: "reader failed") }

        // One tracking step: perform all live requests on the sequence handler, update observations,
        // and return per-point tracked centers (top-left normalized; nil for lost points).
        func step(
            _ seq: VNSequenceRequestHandler, _ obs: inout [VNDetectedObjectObservation?],
            _ buffer: CVPixelBuffer
        ) -> [CGPoint?] {
            var reqs: [VNTrackObjectRequest] = []
            var idxs: [Int] = []
            for (i, o) in obs.enumerated() {
                guard let o else { continue }
                let r = VNTrackObjectRequest(detectedObjectObservation: o)
                r.trackingLevel = .accurate
                reqs.append(r); idxs.append(i)
            }
            var centers = [CGPoint?](repeating: nil, count: obs.count)
            if !reqs.isEmpty, (try? seq.perform(reqs, on: buffer, orientation: orientation)) != nil {
                for (k, r) in reqs.enumerated() {
                    let i = idxs[k]
                    if let res = r.results?.first as? VNDetectedObjectObservation, res.confidence >= 0.3 {
                        obs[i] = res
                        let b = res.boundingBox
                        centers[i] = CGPoint(x: b.midX, y: 1 - b.midY)
                    } else {
                        obs[i] = nil
                    }
                }
            }
            return centers
        }

        let backwardStart = max(0, seedFrame - maxBackwardFrames)
        var backward: [CVPixelBuffer] = []          // frames [backwardStart, seedFrame), forward order
        var forwardTransforms: [StabFrameTransform] = []   // frames [seedFrame, end]
        var forwardSeq = VNSequenceRequestHandler()
        var forwardObs: [VNDetectedObjectObservation?] = seedObservations.map { Optional($0) }
        var forwardLast = seedTransform
        var index = 0
        var processed = 0

        while true {
            try Task.checkCancellation()
            let finished = autoreleasepool { () -> Bool in
                guard let sample = output.copyNextSampleBuffer(),
                      let buffer = CMSampleBufferGetImageBuffer(sample) else { return true }
                if index < seedFrame {
                    if index >= backwardStart, let copy = copyPixelBuffer(buffer) {
                        backward.append(copy)
                    }
                } else if index == seedFrame {
                    forwardTransforms.append(seedTransform)
                    forwardLast = seedTransform
                    forwardObs = seedObservations.map { Optional($0) }
                    forwardSeq = VNSequenceRequestHandler()
                } else {
                    let centers = step(forwardSeq, &forwardObs, buffer)
                    forwardLast = transform(
                        from: centers, reference: seedPointsTopLeft, last: forwardLast, aspect: aspect)
                    forwardTransforms.append(forwardLast)
                }
                index += 1
                processed += 1
                // Read/forward pass fills 0→0.6; the backward pass fills 0.6→1.0.
                if processed % 10 == 0 { progress(min(0.6, 0.6 * Double(processed) / Double(estTotal))) }
                return false
            }
            if finished { break }
            if index % 30 == 0 { await Task.yield() }
        }

        let total = index
        guard total > 0 else { throw Failure(reason: "no frames") }
        if seedFrame > maxBackwardFrames {
            Log.proxy.notice("points backward-track capped at \(maxBackwardFrames) frames (seed=\(seedFrame))")
        }

        // Frames before the cap hold the seed transform; forward + backward fills overwrite the rest.
        var frames = [StabFrameTransform](repeating: seedTransform, count: total)
        for (i, t) in forwardTransforms.enumerated() {
            let f = seedFrame + i
            if f >= 0, f < total { frames[f] = t }
        }
        var backSeq = VNSequenceRequestHandler()
        var backObs: [VNDetectedObjectObservation?] = seedObservations.map { Optional($0) }
        var backLast = seedTransform
        let backCount = backward.count
        for (done, j) in stride(from: backCount - 1, through: 0, by: -1).enumerated() {
            try Task.checkCancellation()
            autoreleasepool {
                let centers = step(backSeq, &backObs, backward[j])
                backLast = transform(
                    from: centers, reference: seedPointsTopLeft, last: backLast, aspect: aspect)
                frames[backwardStart + j] = backLast
            }
            if (done + 1) % 30 == 0 {
                progress(min(1, 0.6 + 0.4 * Double(done + 1) / Double(max(1, backCount))))
                await Task.yield()
            }
        }

        progress(1)
        return (fps == 0 ? 30 : fps, frames)
    }

    /// Cap the long edge at ~720px to bound reader-buffer memory; preserve aspect, never upscale.
    private static func downscaledDims(_ size: CGSize, longEdge: CGFloat = 720) -> (Int, Int) {
        let w = abs(size.width), h = abs(size.height)
        guard w > 0, h > 0 else { return (Int(longEdge), Int(longEdge)) }
        let scale = min(1, longEdge / max(w, h))
        return (max(1, Int((w * scale).rounded())), max(1, Int((h * scale).rounded())))
    }

    /// Deep-copy a pixel buffer so it survives past the reader's sample lifetime.
    private static func copyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        let fmt = CVPixelBufferGetPixelFormatType(src)
        var dst: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, fmt, attrs, &dst) == kCVReturnSuccess,
              let out = dst else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(src),
              let d = CVPixelBufferGetBaseAddress(out) else { return nil }
        let sbpr = CVPixelBufferGetBytesPerRow(src)
        let dbpr = CVPixelBufferGetBytesPerRow(out)
        let rowBytes = min(sbpr, dbpr)
        for row in 0..<h { memcpy(d + row * dbpr, s + row * sbpr, rowBytes) }
        return out
    }

    /// Orientation that uprights a frame given its track's preferredTransform, so Vision runs in the
    /// same (display) space as the picker. Identity → `.up` (no-op).
    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (atan2(t.b, t.a) * 180 / .pi).rounded() {
        case 90: return .right
        case -90: return .left
        case 180, -180: return .down
        default: return .up
        }
    }
}
