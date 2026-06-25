import AVFoundation
import CoreImage
import os

enum ProxyService {
    struct Failure: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    private enum FrameOutcome { case keepGoing, finished, readerFailed, appendFailed }

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

        var audioReader: AVAssetReader?
        var readerAudio: AVAssetReaderTrackOutput?
        var writerAudio: AVAssetWriterInput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let ar = try AVAssetReader(asset: asset)
            let ra = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            ar.add(ra); audioReader = ar; readerAudio = ra
            let wa = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100, AVEncoderBitRateKey: 128_000,
            ])
            wa.expectsMediaDataInRealTime = false
            writer.add(wa); writerAudio = wa
        }

        Log.proxy.notice("tx setup \(Int(absSize.width))x\(Int(absSize.height))->\(Int(target.width))x\(Int(target.height)) dur=\(String(format: "%.1f", duration.seconds))s audio=\(readerAudio != nil)")
        guard reader.startReading() else { throw Failure(reason: reader.error?.localizedDescription ?? "reader failed") }
        if let audioReader {
            guard audioReader.startReading() else { throw Failure(reason: audioReader.error?.localizedDescription ?? "audio reader failed") }
        }
        guard writer.startWriting() else { throw Failure(reason: writer.error?.localizedDescription ?? "writer failed") }
        writer.startSession(atSourceTime: .zero)
        Log.proxy.notice("tx reading (writer started)")

        let ciContext = CIContext()
        let scaleX = target.width / absSize.width
        let scaleY = target.height / absSize.height

        let frames = OSAllocatedUnfairLock(initialState: 0)
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
                    // Drain per frame: a tiny ProRes output never back-pressures, so this
                    // block loops without returning; without the pool each ~100 MB 6K
                    // decoded buffer is held until the decoder's pool starves and stalls.
                    let outcome: FrameOutcome = autoreleasepool {
                        guard let sample = readerVideo.copyNextSampleBuffer(),
                              let src = CMSampleBufferGetImageBuffer(sample) else {
                            return reader.status == .failed ? .readerFailed : .finished
                        }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard let pool = adaptor.pixelBufferPool else { return .keepGoing }
                        var outBuf: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                        guard let outBuf else { return .keepGoing }
                        let img = CIImage(cvPixelBuffer: src)
                            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                        ciContext.render(img, to: outBuf)
                        guard adaptor.append(outBuf, withPresentationTime: time) else { return .appendFailed }
                        let n = frames.withLock { $0 += 1; return $0 }
                        if n == 1 { Log.proxy.notice("tx first frame appended") }
                        if duration.seconds > 0 { progress(min(1, time.seconds / duration.seconds)) }
                        return .keepGoing
                    }
                    switch outcome {
                    case .keepGoing: continue
                    case .finished: writerVideo.markAsFinished(); finish(.success(())); return
                    case .readerFailed: finish(.failure(reader.error ?? Failure(reason: "reader failed"))); return
                    case .appendFailed: finish(.failure(writer.error ?? Failure(reason: "writer append failed"))); return
                    }
                }
            }
        }
        Log.proxy.notice("tx video pass done frames=\(frames.withLock { $0 })")

        if let audioReader, let readerAudio, let writerAudio {
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
                            audioReader.cancelReading()
                            finish(.failure(CancellationError()))
                            return
                        }
                        guard let sample = readerAudio.copyNextSampleBuffer() else {
                            if audioReader.status == .failed {
                                finish(.failure(audioReader.error ?? Failure(reason: "audio reader failed")))
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

        Log.proxy.notice("tx finishing")
        await writer.finishWriting()
        Log.proxy.notice("tx finished status=\(writer.status.rawValue)")
        if writer.status != .completed {
            throw Failure(reason: writer.error?.localizedDescription ?? "writer did not complete")
        }
        progress(1)
    }
}
