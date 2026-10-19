import AVFoundation
import CoreVideo
import Foundation

/// Named media fixtures for indexer tests: two-tone H.264 `.mov` and mono Int16 WAV sine.
enum TestMedia {
    /// H.264 `.mov` of `seconds` with a black first half and white second half (strong luma cut).
    static func makeVideo(seconds: Double, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).mov")
        let size = 320
        let fps: Int32 = 5
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let half = seconds / 2
        var frameIndex: Int64 = 0
        for (value, span) in [(UInt8(0), half), (UInt8(255), seconds - half)] {
            let buffer = try solidBuffer(value: value, size: size, pool: adaptor.pixelBufferPool)
            let frameCount = max(1, Int(span * Double(fps)))
            for _ in 0..<frameCount {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else {
                        throw writer.error ?? NSError(domain: "TestMedia", code: 6)
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: fps)) else {
                    throw writer.error ?? NSError(domain: "TestMedia", code: 1)
                }
                frameIndex += 1
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "TestMedia", code: 2)
        }
        return url
    }

    /// Mono Int16 440 Hz sine WAV of `seconds` at `sampleRate`.
    static func makeWAV(seconds: Double, sampleRate: Double, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw NSError(domain: "TestMedia", code: 3)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "TestMedia", code: 4)
        }
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            samples[i] = Float(sin(2 * .pi * 440 * t) * 0.5)
        }
        try file.write(from: buffer)
        return url
    }

    private static func solidBuffer(value: UInt8, size: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { throw NSError(domain: "TestMedia", code: 5) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(value), CVPixelBufferGetDataSize(buffer))
        return buffer
    }
}
