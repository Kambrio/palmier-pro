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

        let tempURL = output.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(output.lastPathComponent)")
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)

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

        // From here the writer may have created a partial file — clean up on any failure.
        do {
            writer.startSession(atSourceTime: .zero)
            Log.proxy.notice("tx reading (writer started)")

            let ciContext = CIContext()
            let scaleX = target.width / absSize.width
            let scaleY = target.height / absSize.height

            // Drain video and audio CONCURRENTLY. AVAssetWriter throttles one input when the
            // other lags (to keep tracks aligned), so feeding all video before any audio
            // deadlocks the video input a frame in. Resume when both inputs finish, or on
            // first error.
            let frames = OSAllocatedUnfairLock(initialState: 0)
            let hasAudio = audioReader != nil && readerAudio != nil && writerAudio != nil
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let state = OSAllocatedUnfairLock(initialState: (done: false, remaining: hasAudio ? 2 : 1))
                @Sendable func isDone() -> Bool { state.withLock { $0.done } }
                @Sendable func fail(_ error: Error) {
                    let resume = state.withLock { s -> Bool in if s.done { return false }; s.done = true; return true }
                    if resume { cont.resume(throwing: error) }
                }
                @Sendable func finishedOne() {
                    let resume = state.withLock { s -> Bool in
                        if s.done { return false }
                        s.remaining -= 1
                        if s.remaining == 0 { s.done = true; return true }
                        return false
                    }
                    if resume { cont.resume(returning: ()) }
                }

                writerVideo.requestMediaDataWhenReady(on: DispatchQueue(label: "io.palmier.proxy.video")) {
                    while writerVideo.isReadyForMoreMediaData {
                        if isDone() { return }
                        if Task.isCancelled { fail(CancellationError()); return }
                        // autoreleasepool: each iteration holds a ~100 MB 6K decoded buffer.
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
                        case .finished: writerVideo.markAsFinished(); finishedOne(); return
                        case .readerFailed: fail(reader.error ?? Failure(reason: "reader failed")); return
                        case .appendFailed: fail(writer.error ?? Failure(reason: "writer append failed")); return
                        }
                    }
                }

                if let aReader = audioReader, let aOut = readerAudio, let aIn = writerAudio {
                    aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "io.palmier.proxy.audio")) {
                        while aIn.isReadyForMoreMediaData {
                            if isDone() { return }
                            if Task.isCancelled { fail(CancellationError()); return }
                            guard let sample = aOut.copyNextSampleBuffer() else {
                                if aReader.status == .failed { fail(aReader.error ?? Failure(reason: "audio reader failed")) }
                                else { aIn.markAsFinished(); finishedOne() }
                                return
                            }
                            if !aIn.append(sample) { fail(writer.error ?? Failure(reason: "audio append failed")); return }
                        }
                    }
                }
            }
            Log.proxy.notice("tx av pass done frames=\(frames.withLock { $0 })")

            Log.proxy.notice("tx finishing")
            await writer.finishWriting()
            Log.proxy.notice("tx finished status=\(writer.status.rawValue)")
            if writer.status != .completed {
                throw Failure(reason: writer.error?.localizedDescription ?? "writer did not complete")
            }
            // finishWriting() can report .completed under memory pressure while the moov atom
            // never durably lands → a substantial but unopenable file. Verify before publishing.
            try Task.checkCancellation()
            guard await isOpenableVideo(tempURL) else {
                throw Failure(reason: "proxy finalized but is not openable (moov missing)")
            }
            // Atomic publish: the final path only ever holds a verified, openable file.
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: tempURL, to: output)
            progress(1)
        } catch {
            // Interrupted/failed writes leave an unfinalized (moov-less) file; remove it so a
            // corrupt proxy is never left behind for the manifest to trust.
            if writer.status == .writing { writer.cancelWriting() }   // cancelWriting() deletes the temp file
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// True if the file at `url` is an openable movie with a video track (a finalized proxy).
    static func isOpenableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video) else { return false }
        return !tracks.isEmpty
    }
}
