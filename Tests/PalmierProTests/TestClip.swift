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
}
