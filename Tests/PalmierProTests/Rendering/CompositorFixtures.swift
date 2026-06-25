import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PalmierPro

/// Shared fixtures for compositor / effect rendering tests: an asymmetric quadrant
/// pattern (TL red, TR green, BL blue, BR white) so flips, rotations, and crops all
/// produce measurably distinct frames, plus a still-video, clip, and timeline built on it.
enum CompositorFixtures {
    static let renderSize = CGSize(width: 320, height: 180)

    static func patternPNG(size: CGSize) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compositor-pattern-\(Int(size.width))x\(Int(size.height)).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // CGContext is bottom-left origin: top quadrants sit in the upper half.
        func fill(_ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(rect)
        }
        fill(1, 0, 0, CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        fill(0, 1, 0, CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        fill(0, 0, 1, CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        fill(1, 1, 1, CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))

        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "fixture", code: 1) }
        return url
    }

    static func patternVideoURL() async throws -> URL {
        let png = try patternPNG(size: renderSize)
        return try await ImageVideoGenerator.stillVideo(for: png, mediaRef: "compositor-pattern", size: renderSize)
    }

    static func patternClip(id: String = "c1", start: Int = 0, duration: Int = 60) -> Clip {
        Fixtures.clip(id: id, mediaRef: "pattern", start: start, duration: duration)
    }

    /// Unclipped mid-tone color quadrants for effect-delta tests. The saturated pattern
    /// pins every channel to 0/255, so brighten/highlights/sharpen have no headroom and
    /// their deltas become renderer-dependent (they vanish on the headless CI runner).
    /// These levels leave room both ways while keeping chroma for saturation/temperature.
    static func midtonePNG(size: CGSize) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compositor-midtone-\(Int(size.width))x\(Int(size.height)).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        func fill(_ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(rect)
        }
        fill(0.70, 0.43, 0.35, CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        fill(0.27, 0.59, 0.39, CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        fill(0.35, 0.43, 0.75, CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        fill(0.55, 0.55, 0.55, CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))

        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "fixture", code: 1) }
        return url
    }

    static func midtoneVideoURL() async throws -> URL {
        let png = try midtonePNG(size: renderSize)
        return try await ImageVideoGenerator.stillVideo(for: png, mediaRef: "compositor-midtone", size: renderSize)
    }

    static func midtoneClip(id: String = "c1", start: Int = 0, duration: Int = 60) -> Clip {
        Fixtures.clip(id: id, mediaRef: "midtone", start: start, duration: duration)
    }

    static func timeline(_ tracks: [Track], size: CGSize = renderSize) -> Timeline {
        var t = Fixtures.timeline(tracks: tracks)
        t.width = Int(size.width)
        t.height = Int(size.height)
        return t
    }

    /// Writes a short solid-gray H.264 `.mov` at the given dimensions and returns its URL.
    static func makeSolidVideo(width: Int, height: Int, seconds: Double) async throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solid-\(width)x\(height)-\(UUID().uuidString).mov")

        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else {
            throw NSError(domain: "fixture", code: 2)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let ptr = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(ptr, 128, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw NSError(domain: "fixture", code: 3) }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let endValue = CMTimeValue(max(1, Double(timescale) * seconds - 1))
        for time in [CMTime.zero, CMTime(value: endValue, timescale: timescale)] {
            while !adaptor.assetWriterInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw NSError(domain: "fixture", code: 4)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw NSError(domain: "fixture", code: 5) }
        return url
    }
}
