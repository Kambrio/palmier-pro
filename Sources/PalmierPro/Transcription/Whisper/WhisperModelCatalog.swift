import Foundation

struct WhisperModel: Identifiable, Sendable, Equatable {
    let id: String          // stable, persisted ("small"/"medium"/"turbo")
    let displayName: String
    let repo: String        // WhisperKit/HuggingFace repo variant
    let approxBytes: Int64
    let hint: String        // short speed/quality note

    var approxSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file)
    }
}

enum WhisperModelCatalog {
    static let all: [WhisperModel] = [
        WhisperModel(id: "small",  displayName: "Small",  repo: "openai_whisper-small",
                     approxBytes: 500_000_000,  hint: "Fastest, lowest accuracy"),
        WhisperModel(id: "medium", displayName: "Medium", repo: "openai_whisper-medium",
                     approxBytes: 1_500_000_000, hint: "Balanced"),
        WhisperModel(id: "turbo",  displayName: "Large v3 Turbo", repo: "openai_whisper-large-v3-turbo",
                     approxBytes: 1_500_000_000, hint: "Best accuracy (recommended)"),
    ]

    static let defaultModelId = "turbo"

    static func model(id: String) -> WhisperModel? { all.first { $0.id == id } }

    /// BCP-47 language codes Whisper handles. Whisper is multilingual (~99 languages);
    /// this is the subset surfaced in the picker as Whisper-capable, kept broad enough
    /// to cover Apple's gaps. Stored as language codes (no region).
    static let languages: Set<String> = [
        "en","zh","de","es","ru","ko","fr","ja","pt","tr","pl","ca","nl","ar","sv","it",
        "id","hi","fi","vi","he","uk","el","ms","cs","ro","da","hu","ta","no","th","ur",
        "hr","bg","lt","la","mi","ml","cy","sk","te","fa","lv","bn","sr","az","sl","kn",
        "et","mk","br","eu","is","hy","ne","mn","bs","kk","sq","sw","gl","mr","pa","si",
    ]
}
