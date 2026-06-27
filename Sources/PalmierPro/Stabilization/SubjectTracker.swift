import AVFoundation
import Vision

enum SubjectTracker {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Cap on buffered backward frames (proxy-res CVPixelBuffers). Beyond it, earlier frames hold the
    /// seed center constant.
    static let maxBackwardFrames = 900

    /// Track a user-picked subject from `seedFrame` both forward (to end) and backward (to 0).
    /// `seedBoxTopLeft` is normalized, TOP-LEFT. Output is one center per source frame, top-left.
    static func track(
        input: URL,
        seedFrame: Int,
        seedBoxTopLeft: CGRect,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (fps: Double, frames: [StabFrameTransform]) {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(reason: "no video track")
        }
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let estTotal = max(1, Int((duration * max(1, fps)).rounded()))
        let (outW, outH) = downscaledDims(try await track.load(.naturalSize))
        // Operate in display (upright) orientation so the seed — picked on an upright frame — matches.
        let orientation = orientation(from: try await track.load(.preferredTransform))

        // TOP-LEFT seed box → Vision bottom-left observation; center kept in top-left.
        let tl = seedBoxTopLeft
        let visionBox = CGRect(x: tl.minX, y: 1 - tl.minY - tl.height, width: tl.width, height: tl.height)
        let seedObservation = VNDetectedObjectObservation(boundingBox: visionBox)
        let seedCenter = CGPoint(x: tl.midX, y: tl.midY)

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

        let backwardStart = max(0, seedFrame - maxBackwardFrames)
        var backward: [CVPixelBuffer] = []      // frames [backwardStart, seedFrame), forward order
        var forwardCenters: [CGPoint] = []       // frames [seedFrame, end]
        var forwardSeq = VNSequenceRequestHandler()
        var forwardObs = seedObservation
        var forwardLast = seedCenter
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
                    forwardCenters.append(seedCenter)
                    forwardLast = seedCenter
                    forwardObs = seedObservation
                    forwardSeq = VNSequenceRequestHandler()
                } else {
                    let req = VNTrackObjectRequest(detectedObjectObservation: forwardObs)
                    req.trackingLevel = .accurate
                    if (try? forwardSeq.perform([req], on: buffer, orientation: orientation)) != nil,
                       let r = req.results?.first as? VNDetectedObjectObservation, r.confidence > 0.3 {
                        let b = r.boundingBox
                        forwardLast = CGPoint(x: b.midX, y: 1 - b.midY)
                        forwardObs = r
                    }
                    forwardCenters.append(forwardLast)
                }
                index += 1
                processed += 1
                if processed % 10 == 0 { progress(min(1, Double(processed) / Double(estTotal))) }
                return false
            }
            if finished { break }
            if index % 30 == 0 { await Task.yield() }
        }

        let total = index
        guard total > 0 else { throw Failure(reason: "no frames") }
        if seedFrame > maxBackwardFrames {
            Log.proxy.notice("subject backward-track capped at \(maxBackwardFrames) frames (seed=\(seedFrame))")
        }

        // Frames before the cap hold the seed center; forward + backward fills overwrite the rest.
        var centers = [CGPoint](repeating: seedCenter, count: total)
        for (i, c) in forwardCenters.enumerated() {
            let f = seedFrame + i
            if f >= 0, f < total { centers[f] = c }
        }
        var backSeq = VNSequenceRequestHandler()
        var backObs = seedObservation
        var backLast = seedCenter
        for j in stride(from: backward.count - 1, through: 0, by: -1) {
            try Task.checkCancellation()
            autoreleasepool {
                let req = VNTrackObjectRequest(detectedObjectObservation: backObs)
                req.trackingLevel = .accurate
                if (try? backSeq.perform([req], on: backward[j], orientation: orientation)) != nil,
                   let r = req.results?.first as? VNDetectedObjectObservation, r.confidence > 0.3 {
                    let b = r.boundingBox
                    backLast = CGPoint(x: b.midX, y: 1 - b.midY)
                    backObs = r
                }
                centers[backwardStart + j] = backLast
            }
        }

        let frames = centers.map {
            StabFrameTransform(m: [1, 0, Double($0.x), 0, 1, Double($0.y), 0, 0, 1])
        }
        progress(1)
        return (fps == 0 ? 30 : fps, frames)
    }

    /// Cap the long edge at ~720px to bound reader-buffer memory (4K×900 frames ≈ 30GB otherwise);
    /// preserve aspect, never upscale. Centers are normalized so the sidecar stays resolution-independent.
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
        let (outW, outH) = downscaledDims(try await track.load(.naturalSize))
        let orientation = orientation(from: try await track.load(.preferredTransform))

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
                    if (try? seq.perform([req], on: buffer, orientation: orientation)) != nil,
                       let r = req.results?.first as? VNDetectedObjectObservation,
                       r.confidence > 0.3 {
                        box = r.boundingBox
                        lastObservation = r
                    } else {
                        lastObservation = nil
                    }
                }
                if box == nil {
                    if let b = detectSubject(buffer, orientation: orientation) {
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
    private static func detectSubject(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGRect? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
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

    /// Orientation that uprights a frame given its track's preferredTransform, so Vision runs in the
    /// same (display) space as the picker. Identity (proxies, unrotated source) → `.up` (no-op).
    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (atan2(t.b, t.a) * 180 / .pi).rounded() {
        case 90: return .right
        case -90: return .left
        case 180, -180: return .down
        default: return .up
        }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
