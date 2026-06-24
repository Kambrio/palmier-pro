import Testing
import Foundation
@testable import PalmierPro

struct AvailableLanguagesTests {
    @Test func whisperOnlyDetectionFlagsRussianWhenAppleLacksIt() {
        let appleCodes: Set<String> = ["en", "es", "fr"]   // pretend Apple lacks ru
        #expect(Transcription.isWhisperOnly(Locale(identifier: "ru"), appleCodes: appleCodes))
        #expect(!Transcription.isWhisperOnly(Locale(identifier: "en"), appleCodes: appleCodes))
    }

    @Test func nonWhisperLanguageIsNotFlagged() {
        let appleCodes: Set<String> = ["en"]
        // "zz" is neither Apple nor Whisper
        #expect(!Transcription.isWhisperOnly(Locale(identifier: "zz"), appleCodes: appleCodes))
    }
}
