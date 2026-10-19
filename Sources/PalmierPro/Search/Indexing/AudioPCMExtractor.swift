import AVFoundation
import Foundation

/// Reads any audio-bearing file as mono 16 kHz Float PCM, sliced into ≤ chunkSeconds spans.
enum AudioPCMExtractor {
    static func mono16kChunks(url: URL, chunkSeconds: Double = 30) async throws -> [(start: Double, samples: [Float])] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVSampleRateKey: 16_000,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let reader = try AVAssetReader(asset: asset)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { reader.cancelReading() }

        let rate = 16_000.0
        let take = max(1, Int(rate * chunkSeconds))
        var chunks: [(start: Double, samples: [Float])] = []
        var carry: [Float] = []
        var chunkStart = 0.0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            carry += monoSamples(sampleBuffer)
            while carry.count >= take {
                chunks.append((start: chunkStart, samples: Array(carry.prefix(take))))
                carry.removeFirst(take)
                chunkStart += chunkSeconds
            }
        }
        if !carry.isEmpty { chunks.append((start: chunkStart, samples: carry)) }
        return chunks
    }

    /// Output settings pin Float32 non-interleaved, so channel data is contiguous per channel.
    private static func monoSamples(_ buffer: CMSampleBuffer) -> [Float] {
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0,
              let description = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
              asbd.mBitsPerChannel == 32,
              let block = CMSampleBufferGetDataBuffer(buffer)
        else { return [] }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels >= 1 else { return [] }
        var lengthAtOffset = 0
        var totalLength = 0
        var raw: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength, dataPointerOut: &raw) == kCMBlockBufferNoErr,
              let raw, totalLength >= frames * channels * 4
        else { return [] }
        let floats = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: Float.self)
        let count = Int(frames)
        guard channels > 1 else {
            return Array(UnsafeBufferPointer(start: floats, count: count))
        }
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channels {
            let channel = UnsafeBufferPointer(start: floats + c * count, count: count)
            for i in 0..<count { mono[i] += channel[i] }
        }
        for i in mono.indices { mono[i] /= Float(channels) }
        return mono
    }
}
