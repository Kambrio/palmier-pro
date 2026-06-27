import AVFoundation
import CoreImage
import Foundation

/// Generates synthetic clips for stabilization tests.
enum TestClip {
    /// A clip where a textured square slides horizontally `pxPerFrame` each frame
    /// over a textured background (so Vision has features to register).
    static func makePanningClip(frames: Int, pxPerFrame: Int, size: Int = 256) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let ctx = CIContext()
        // Textured background gives Vision registration trackable features.
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32ARGB, nil, &pb)
            guard let buffer = pb else { continue }
            let x = CGFloat(20 + i * pxPerFrame)
            let sq = CIImage(color: .white)
                .cropped(to: CGRect(x: x, y: CGFloat(size/2 - 20), width: 40, height: 40))
                .composited(over: noise)
            ctx.render(sq, to: buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// A clip with a rigid set of bright dots that translate (`pxPerFrame` in x) AND rotate
    /// (`degPerFrame` about their centroid) each frame, over a textured background so the patches
    /// have features to register. `dots` are top-left normalized positions at frame 0. Returns the URL
    /// and the dots' positions (top-left normalized) at `seedFrame` for use as the tracker's seed.
    /// (Core Image renders bottom-left, so display top-left y = 1 − ciY.)
    static func makeRigidDotsClip(
        frames: Int, dots: [CGPoint], pxPerFrame: Int, degPerFrame: Double, seedFrame: Int,
        size: Int = 256
    ) async throws -> (url: URL, seedPoints: [CGPoint]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let ctx = CIContext()
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let sz = CGFloat(size)
        // CI (bottom-left) dot positions at frame 0, and their centroid (rotation pivot).
        let ciDots = dots.map { CGPoint(x: $0.x * sz, y: (1 - $0.y) * sz) }
        let cx = ciDots.reduce(0.0) { $0 + $1.x } / CGFloat(ciDots.count)
        let cy = ciDots.reduce(0.0) { $0 + $1.y } / CGFloat(ciDots.count)
        let dotPx: CGFloat = 18
        var seedPoints: [CGPoint] = []
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32ARGB, nil, &pb)
            guard let buffer = pb else { continue }
            let theta = Double(i) * degPerFrame * .pi / 180
            let tx = CGFloat(i * pxPerFrame)
            var img = noise
            for ci in ciDots {
                // Rotate about centroid, then translate in x.
                let rx = cx + CGFloat(cos(theta)) * (ci.x - cx) - CGFloat(sin(theta)) * (ci.y - cy) + tx
                let ry = cy + CGFloat(sin(theta)) * (ci.x - cx) + CGFloat(cos(theta)) * (ci.y - cy)
                let dot = CIImage(color: .white)
                    .cropped(to: CGRect(x: rx - dotPx / 2, y: ry - dotPx / 2, width: dotPx, height: dotPx))
                img = dot.composited(over: img)
                if i == seedFrame { seedPoints.append(CGPoint(x: rx / sz, y: 1 - ry / sz)) }
            }
            ctx.render(img.cropped(to: CGRect(x: 0, y: 0, width: size, height: size)), to: buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return (url, seedPoints)
    }

    /// A clip where the ENTIRE textured frame pans horizontally `pxPerFrame` each frame —
    /// exercises whole-frame camera-motion registration (unlike a single moving object).
    static func makeGlobalPanClip(frames: Int, pxPerFrame: Int, size: Int = 400) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let ctx = CIContext()
        // A large textured field, sampled through a window that slides — so the whole frame moves.
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32ARGB, nil, &pb)
            guard let buffer = pb else { continue }
            let shift = CGFloat(i * pxPerFrame)
            let framed = noise
                .transformed(by: CGAffineTransform(translationX: -shift, y: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
            ctx.render(framed, to: buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
}
