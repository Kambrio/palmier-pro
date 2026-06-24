import Foundation
import WhisperKit

/// Sole owner of the WhisperKit dependency. Returns only the neutral RawTranscript so
/// callers never touch WhisperKit's TranscriptionResult/TranscriptionSegment, which
/// collide by name with Palmier's own types.
actor WhisperKitRunner {
    private var pipe: WhisperKit?
    private var loadedRepo: String?

    static func download(
        repo: String,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return try await WhisperKit.download(
            variant: repo,
            downloadBase: destination,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { p in progress(p.fractionCompleted) }
        )
    }

    private func ensureLoaded(repo: String, modelFolder: URL) async throws {
        if loadedRepo == repo, pipe != nil { return }
        do {
            let config = WhisperKitConfig(model: repo, modelFolder: modelFolder.path, download: false)
            pipe = try await WhisperKit(config)
            loadedRepo = repo
        } catch {
            pipe = nil
            loadedRepo = nil
            throw TranscriptionError.whisperLoadFailed(error.localizedDescription)
        }
    }

    func unload() {
        pipe = nil
        loadedRepo = nil
    }

    func detectLanguage(repo: String, modelFolder: URL, audioPath: String) async throws -> String? {
        try await ensureLoaded(repo: repo, modelFolder: modelFolder)
        guard let pipe else { return nil }
        return try? await pipe.detectLanguage(audioPath: audioPath).language
    }

    func transcribe(
        repo: String,
        modelFolder: URL,
        audioPath: String,
        language: String?
    ) async throws -> RawTranscript {
        try await ensureLoaded(repo: repo, modelFolder: modelFolder)
        guard let pipe else { throw TranscriptionError.whisperLoadFailed("pipeline unavailable") }

        let options = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            wordTimestamps: true
        )

        var rawSegments: [RawSegment] = []
        var detected: String?

        do {
            // Inferred element type is WhisperKit's TranscriptionResult; never spelled to avoid colliding with Palmier's.
            for r in try await pipe.transcribe(audioPath: audioPath, decodeOptions: options) {
                if detected == nil { detected = r.language }
                for seg in r.segments {
                    let words: [RawWord] = (seg.words ?? []).map {
                        RawWord(text: $0.word, start: Double($0.start), end: Double($0.end))
                    }
                    rawSegments.append(
                        RawSegment(text: seg.text, start: Double(seg.start), end: Double(seg.end), words: words)
                    )
                }
            }
        } catch {
            throw TranscriptionError.whisperTranscribeFailed(error.localizedDescription)
        }

        return RawTranscript(detectedLanguage: detected, segments: rawSegments)
    }
}
