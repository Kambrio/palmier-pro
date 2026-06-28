import Foundation

/// One utterance the worker synthesizes to `output` (an absolute WAV path).
struct OmniVoiceSegment: Encodable, Sendable {
    let text: String
    let output: String
    var instruct: String? = nil     // voice-design attributes (gender/age/accent/whisper)
    var duration: Double? = nil     // force exact output length, seconds
    var speed: Double? = nil

    enum CodingKeys: String, CodingKey { case text, output, instruct, duration, speed }
}

/// Single-language worker config. `refAudio == nil` means no voice cloning
/// (plain TTS or, with per-segment `instruct`, voice design).
struct OmniVoiceJob: Encodable, Sendable {
    var refAudio: String? = nil
    let language: String
    let segments: [OmniVoiceSegment]
    var numStep: Int = 16           // 16 ≈ 2× faster than the 32-step default
    var refText: String? = nil      // optional reference transcription; worker auto-ASRs if nil

    enum CodingKeys: String, CodingKey {
        case refAudio = "ref_audio"
        case language
        case segments
        case numStep = "num_step"
        case refText = "ref_text"
    }
}
