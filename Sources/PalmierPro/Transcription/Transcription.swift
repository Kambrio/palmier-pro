import AVFoundation
import Foundation
import Speech

enum TranscriptionProvider: String, CaseIterable, Sendable, Codable {
    case local
    case cloud

    var label: String {
        switch self {
        case .local: L10n.key("Local")
        case .cloud: L10n.key("Cloud")
        }
    }
}

struct TranscriptionWord: Sendable, Codable {
    let text: String
    let start: Double?
    let end: Double?
    let speaker: String?

    init(text: String, start: Double?, end: Double?, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

struct TranscriptionSegment: Sendable, Codable {
    let text: String
    let start: Double
    let end: Double
    let speaker: String?

    init(text: String, start: Double, end: Double, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

struct TranscriptionResult: Sendable, Codable {
    let text: String
    let language: String?
    let words: [TranscriptionWord]
    let segments: [TranscriptionSegment]

    /// Shifts all timestamps back into source time after transcribing an extracted range
    func offsetting(by offset: Double) -> TranscriptionResult {
        guard offset != 0 else { return self }
        return TranscriptionResult(
            text: text,
            language: language,
            words: words.map {
                TranscriptionWord(
                    text: $0.text,
                    start: $0.start.map { $0 + offset },
                    end: $0.end.map { $0 + offset },
                    speaker: $0.speaker
                )
            },
            segments: segments.map {
                TranscriptionSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset, speaker: $0.speaker)
            }
        )
    }
}

enum TranscriptionError: LocalizedError {
    case unsupportedLocale(String)
    case modelInstallFailed(String)
    case decodeFailed
    case audioExtractionFailed(String)
    case analysisFailed(String)
    case whisperModelNotInstalled
    case whisperLoadFailed(String)
    case whisperTranscribeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            return "On-device transcription is not available for \(id)."
        case .modelInstallFailed(let reason):
            return "Could not install the on-device speech model: \(reason)"
        case .decodeFailed:
            return "Could not parse transcription result."
        case .audioExtractionFailed(let reason):
            return "Audio extraction failed: \(reason)"
        case .analysisFailed(let reason):
            return "Transcription failed: \(reason)"
        case .whisperModelNotInstalled:
            return "No Whisper model downloaded — add one in Settings › Transcription."
        case .whisperLoadFailed(let reason):
            return "Could not load the Whisper model: \(reason)"
        case .whisperTranscribeFailed(let reason):
            return "Whisper transcription failed: \(reason)"
        }
    }
}

enum Transcription {
    private static let audioExtractionGate = AsyncSemaphore(value: 2)

    static func failurePreservingCancellation(
        _ error: Error,
        as makeFailure: (String) -> TranscriptionError
    ) throws -> TranscriptionError {
        try Task.checkCancellation()
        return makeFailure(error.localizedDescription)
    }

    static func transcribeVideoAudio(videoURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil, sourceRange: ClosedRange<Double>? = nil) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let tempAudioURL = try await extractAudioTrack(from: videoURL, range: sourceRange)
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }
        let result = try await transcribe(fileURL: tempAudioURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale)
        return result.offsetting(by: sourceRange?.lowerBound ?? 0)
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    static func bestSupportedLocale(from supported: [Locale]) -> Locale? {
        let candidates = Locale.preferredLanguages.map(Locale.init(identifier:)) + [Locale.current]
        return matchLocale(candidates: candidates, supported: supported)
    }

    static func matchLocale(candidates: [Locale], supported: [Locale]) -> Locale? {
        for candidate in candidates {
            // Strip Unicode extension tags (e.g. -u-rg-zazzzz from en-US-u-rg-zazzzz) before
            // matching — the Speech framework doesn't recognise composite BCP 47 tags.
            let baseId = candidate.identifier(.bcp47).components(separatedBy: "-u-").first
                ?? candidate.identifier
            let base = Locale(identifier: baseId)
            guard let lang = base.language.languageCode?.identifier else { continue }
            let sameLang = supported.filter { $0.language.languageCode?.identifier == lang }
            guard !sameLang.isEmpty else { continue }
            let region = base.region?.identifier
            return sameLang.first { $0.region?.identifier == region } ?? sameLang.first
        }
        return nil
    }

    static func transcribe(fileURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil, sourceRange: ClosedRange<Double>? = nil) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        if let sourceRange {
            let tempURL = try await extractAudioTrack(from: fileURL, range: sourceRange)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let result = try await transcribe(fileURL: tempURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale)
            return result.offsetting(by: sourceRange.lowerBound)
        }

        // `fileURL` may already be decoded PCM (from transcribeVideoAudio/range paths); re-decoding is cheap and acceptable.
        let pcmURL = try await extractAudioTrack(from: fileURL)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        return try await route(pcmURL: pcmURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale)
    }

    @MainActor
    static func route(pcmURL: URL, censorProfanity: Bool, preferredLocale: Locale?) async throws -> TranscriptionResult {
        let apple = AppleSpeechBackend()
        let whisper = WhisperBackend()
        let mode = WhisperModelManager.shared.engineMode
        let whisperAvailable = WhisperModelManager.shared.activeModelAvailable

        let requestedLang = preferredLocale?.language.languageCode?.identifier
        var routingLang = requestedLang
        if mode == .automatic, routingLang == nil, whisperAvailable {
            routingLang = try? await whisper.detectLanguage(fileURL: pcmURL)
        }

        let appleLangs = await apple.supportedLanguages()
        let appleSupports = routingLang.map { appleLangs.contains($0) } ?? !appleLangs.isEmpty

        let choice = try TranscriptionRouter.decide(
            mode: mode, appleSupportsLanguage: appleSupports, whisperModelAvailable: whisperAvailable
        )

        let routeLocale = routingLang.map { Locale(identifier: $0) } ?? preferredLocale
        switch choice {
        case .apple:   return try await apple.transcribe(fileURL: pcmURL, language: routeLocale, censorProfanity: censorProfanity)
        case .whisper: return try await whisper.transcribe(fileURL: pcmURL, language: routeLocale, censorProfanity: censorProfanity)
        }
    }

    @MainActor
    static func availableLanguages() async -> [Locale] {
        let apple = await SpeechTranscriber.supportedLocales
        let appleCodes = Set(apple.compactMap { $0.language.languageCode?.identifier })
        let whisperOnly = WhisperModelCatalog.languages
            .subtracting(appleCodes)
            .map { Locale(identifier: $0) }
        return apple + whisperOnly
    }

    static func isWhisperOnly(_ locale: Locale, appleCodes: Set<String>) -> Bool {
        guard let code = locale.language.languageCode?.identifier else { return false }
        return !appleCodes.contains(code) && WhisperModelCatalog.languages.contains(code)
    }

    /// Decode the asset's audio track to a PCM file with AVAssetReader
    static func extractAudioTrack(
        from videoURL: URL,
        range: ClosedRange<Double>? = nil,
        fileExtension: String = "caf"
    ) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-stt-\(UUID().uuidString).\(fileExtension)")
        try await audioExtractionGate.wait()
        defer { Task { await audioExtractionGate.signal() } }

        Log.transcription.notice(
            "extract start video=\(videoURL.lastPathComponent)",
            telemetry: "Transcription audio extraction started",
            data: ["hasRange": range != nil, "rangeSeconds": range.map { $0.upperBound - $0.lowerBound } ?? 0]
        )

        var audioFile: AVAudioFile?
        do {
            try await AudioTrackReader.read(from: videoURL, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], range: range) { pcm in
                if audioFile == nil {
                    audioFile = try AVAudioFile(
                        forWriting: outURL,
                        settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat,
                        interleaved: pcm.format.isInterleaved
                    )
                }
                try audioFile?.write(from: pcm)
            }
        } catch let error as AudioTrackReader.ReadError {
            try Task.checkCancellation()
            throw TranscriptionError.audioExtractionFailed(error.message)
        }

        guard audioFile != nil else {
            throw TranscriptionError.audioExtractionFailed("No audio samples in \(videoURL.lastPathComponent)")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        Log.transcription.notice(
            "extract ok bytes=\(bytes) out=\(outURL.lastPathComponent)",
            telemetry: "Transcription audio extraction finished",
            data: ["bytes": bytes, "hasRange": range != nil]
        )
        return outURL
    }

    /// Each `Result` is one endpointed segment; emit it as a TranscriptionSegment
    /// (text + time range) and walk its runs into per-token TranscriptionWords.
    static func decodeAppleResults(
        _ results: [SpeechTranscriber.Result],
        locale: Locale,
    ) -> TranscriptionResult {
        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var fullText = ""

        for result in results {
            let attributed = result.text
            fullText += String(attributed.characters)

            let segmentText = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segmentText.isEmpty {
                segments.append(TranscriptionSegment(
                    text: segmentText,
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    speaker: nil
                ))
            }

            for run in attributed.runs {
                let runText = String(attributed[run.range].characters)
                let trimmed = runText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let range = run.audioTimeRange
                let start = range.map(\.start.seconds)
                let end = range.map { ($0.start + $0.duration).seconds }
                words.append(TranscriptionWord(text: trimmed, start: start, end: end, speaker: nil))
            }
        }

        return TranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            language: locale.identifier(.bcp47),
            words: words,
            segments: segments,
        )
    }
}
