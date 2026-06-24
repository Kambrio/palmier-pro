import AVFoundation
import Foundation
import Speech

struct AppleSpeechBackend: TranscriptionBackend {
    func supportedLanguages() async -> Set<String> {
        let locales = await SpeechTranscriber.supportedLocales
        return Set(locales.compactMap { $0.language.languageCode?.identifier })
    }

    /// `fileURL` is a decoded 16 kHz mono PCM file (router-extracted). `language`
    /// is matched against supported locales; nil → best system locale.
    func transcribe(fileURL: URL, language: Locale?, censorProfanity: Bool) async throws -> TranscriptionResult {
        let supported = await SpeechTranscriber.supportedLocales
        let locale: Locale
        if let language, let match = Transcription.matchLocale(candidates: [language], supported: supported) {
            locale = match
        } else if language == nil, let auto = Transcription.bestSupportedLocale(from: supported) {
            locale = auto
        } else {
            throw TranscriptionError.unsupportedLocale((language ?? Locale.current).identifier(.bcp47))
        }
        Log.transcription.notice(
            "transcribe locale=\(locale.identifier(.bcp47))",
            telemetry: "Transcription started",
            data: [
                "locale": locale.identifier(.bcp47),
                "censorProfanity": censorProfanity,
                "hasPreferredLocale": language != nil
            ]
        )

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censorProfanity ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.transcription.notice(
                "install model start locale=\(locale.identifier)",
                telemetry: "Transcription model install started",
                data: ["locale": locale.identifier(.bcp47)]
            )
            do { try await install.downloadAndInstall() }
            catch {
                Log.transcription.warning(
                    "install model failed locale=\(locale.identifier) error=\(error.localizedDescription)",
                    telemetry: "Transcription model install failed",
                    data: ["locale": locale.identifier(.bcp47), "error": error.localizedDescription]
                )
                throw TranscriptionError.modelInstallFailed(error.localizedDescription)
            }
            Log.transcription.notice(
                "install model ok locale=\(locale.identifier)",
                telemetry: "Transcription model install finished",
                data: ["locale": locale.identifier(.bcp47)]
            )
        }

        let audioFile: AVAudioFile
        do { audioFile = try AVAudioFile(forReading: fileURL) }
        catch { throw TranscriptionError.audioExtractionFailed(error.localizedDescription) }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultsTask = Task { () throws -> [SpeechTranscriber.Result] in
            var acc: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results { acc.append(result) }
            return acc
        }
        Log.transcription.notice("analyze start file=\(fileURL.lastPathComponent)", telemetry: "Transcription analysis started")
        do {
            if let last = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            resultsTask.cancel()
            Log.transcription.warning(
                "analyze failed error=\(error.localizedDescription)",
                telemetry: "Transcription analysis failed",
                data: ["error": error.localizedDescription]
            )
            throw TranscriptionError.analysisFailed(error.localizedDescription)
        }
        let collected = try await resultsTask.value
        let decoded = Transcription.decodeAppleResults(collected, locale: locale)
        Log.transcription.notice(
            "ok textChars=\(decoded.text.count) words=\(decoded.words.count) lang=\(decoded.language ?? "?")",
            telemetry: "Transcription finished",
            data: [
                "textChars": decoded.text.count,
                "words": decoded.words.count,
                "segments": decoded.segments.count,
                "language": decoded.language ?? "unknown"
            ]
        )
        return decoded
    }
}
