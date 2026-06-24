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

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censorProfanity ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            do { try await install.downloadAndInstall() }
            catch { throw TranscriptionError.modelInstallFailed(error.localizedDescription) }
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
        do {
            if let last = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            resultsTask.cancel()
            throw TranscriptionError.analysisFailed(error.localizedDescription)
        }
        let collected = try await resultsTask.value
        return Transcription.decodeAppleResults(collected, locale: locale)
    }
}
