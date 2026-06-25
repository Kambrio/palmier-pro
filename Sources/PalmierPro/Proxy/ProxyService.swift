import AVFoundation
import CoreImage
import os

enum ProxyService {
    struct Failure: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    /// Transcodes `source` to a ProRes 422 Proxy `.mov` at `to`, scaled to `resolution`; throws `CancellationError` on cancel.
    static func transcode(
        source: URL,
        to output: URL,
        resolution: ProxyResolution,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(reason: "source has no video track")
        }
        let natural = try await videoTrack.load(.naturalSize)
        let transformed = natural.applying(try await videoTrack.load(.preferredTransform))
        let absSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let target = resolution.targetSize(forSource: absSize)
        let duration = try await asset.load(.duration)

        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)

        let readerVideo = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerVideo.alwaysCopiesSampleData = false
        reader.add(readerVideo)

        let writerVideo = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422Proxy,
            AVVideoWidthKey: Int(target.width),
            AVVideoHeightKey: Int(target.height),
        ])
        writerVideo.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerVideo,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(target.width),
                kCVPixelBufferHeightKey as String: Int(target.height),
            ]
        )
        writer.add(writerVideo)

        var readerAudio: AVAssetReaderTrackOutput?
        var writerAudio: AVAssetWriterInput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let ra = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(ra); readerAudio = ra
            let wa = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100, AVEncoderBitRateKey: 128_000,
            ])
            wa.expectsMediaDataInRealTime = false
            writer.add(wa); writerAudio = wa
        }

        guard reader.startReading() else { throw Failure(reason: reader.error?.localizedDescription ?? "reader failed") }
        guard writer.startWriting() else { throw Failure(reason: writer.error?.localizedDescription ?? "writer failed") }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext()
        let scaleX = target.width / absSize.width
        let scaleY = target.height / absSize.height

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: Result<Void, Error>) {
                let already = resumed.withLock { done -> Bool in defer { done = true }; return done }
                guard !already else { return }
                cont.resume(with: result)
            }
            let queue = DispatchQueue(label: "io.palmier.proxy.video")
            writerVideo.requestMediaDataWhenReady(on: queue) {
                while writerVideo.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                        finish(.failure(CancellationError()))
                        return
                    }
                    guard let sample = readerVideo.copyNextSampleBuffer(),
                          let src = CMSampleBufferGetImageBuffer(sample) else {
                        if reader.status == .failed {
                            finish(.failure(reader.error ?? Failure(reason: "reader failed")))
                        } else {
                            writerVideo.markAsFinished()
                            finish(.success(()))
                        }
                        return
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    var outBuf: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                    }
                    if let outBuf {
                        let img = CIImage(cvPixelBuffer: src)
                            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                        ciContext.render(img, to: outBuf)
                        if !adaptor.append(outBuf, withPresentationTime: time) {
                            finish(.failure(writer.error ?? Failure(reason: "writer append failed")))
                            return
                        }
                    }
                    if duration.seconds > 0 { progress(min(1, time.seconds / duration.seconds)) }
                }
            }
        }

        if let readerAudio, let writerAudio {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                @Sendable func finish(_ result: Result<Void, Error>) {
                    let already = resumed.withLock { done -> Bool in defer { done = true }; return done }
                    guard !already else { return }
                    cont.resume(with: result)
                }
                let queue = DispatchQueue(label: "io.palmier.proxy.audio")
                writerAudio.requestMediaDataWhenReady(on: queue) {
                    while writerAudio.isReadyForMoreMediaData {
                        if Task.isCancelled {
                            finish(.failure(CancellationError()))
                            return
                        }
                        guard let sample = readerAudio.copyNextSampleBuffer() else {
                            if reader.status == .failed {
                                finish(.failure(reader.error ?? Failure(reason: "reader failed")))
                            } else {
                                writerAudio.markAsFinished()
                                finish(.success(()))
                            }
                            return
                        }
                        if !writerAudio.append(sample) {
                            finish(.failure(writer.error ?? Failure(reason: "writer append failed")))
                            return
                        }
                    }
                }
            }
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw Failure(reason: writer.error?.localizedDescription ?? "writer did not complete")
        }
        progress(1)
    }
}
