import Foundation

/// The single local TTS model surfaced for the OmniVoice provider.
enum OmniVoiceCatalog {
    static let modelId = "omnivoice-local"

    static let caps = AudioCaps(
        category: "tts",
        voices: nil,
        defaultVoice: nil,
        supportsLyrics: false,
        supportsInstrumental: false,
        supportsStyleInstructions: true,
        durations: nil,
        minPromptLength: 1,
        inputs: ["text"],
        promptLabel: "What should it say?",
        minSeconds: 1,
        maxSeconds: 900
    )

    static let entry = CatalogEntry(
        id: modelId,
        displayName: "OmniVoice (Local)",
        uiCapabilities: .audio(caps),
        audioPricing: .flat(price: 0)
    )

    static let model = AudioModelConfig(entry: entry, caps: caps)
}

extension CatalogEntry {
    /// Convenience init for locally-defined (non-Convex) catalog entries.
    init(
        id: String,
        displayName: String,
        uiCapabilities: UICapabilities,
        audioPricing: AudioPricing?
    ) {
        self.id = id
        self.kind = .audio
        self.displayName = displayName
        self.allowedEndpoints = []
        self.responseShape = .audio
        self.uiCapabilities = uiCapabilities
        self.creditsPerSecond = nil
        self.audioDiscountRate = nil
        self.creditsPerImage = nil
        self.qualities = nil
        self.audioPricing = audioPricing
        self.creditsPerSecondUpscale = nil
    }
}
