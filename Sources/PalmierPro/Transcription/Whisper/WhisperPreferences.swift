import Foundation

enum WhisperPreferences {
    private static let modeKey = "io.palmier.pro.transcription.engineMode"
    private static let activeModelKey = "io.palmier.pro.transcription.activeWhisperModel"

    static var engineMode: TranscriptionEngineMode {
        get {
            UserDefaults.standard.string(forKey: modeKey)
                .flatMap(TranscriptionEngineMode.init(rawValue:)) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// Active Whisper model id. Defaults to the catalog default; may point at a
    /// model that isn't downloaded yet (UI reflects download state separately).
    static var activeModelId: String {
        get { UserDefaults.standard.string(forKey: activeModelKey) ?? WhisperModelCatalog.defaultModelId }
        set { UserDefaults.standard.set(newValue, forKey: activeModelKey) }
    }
}
