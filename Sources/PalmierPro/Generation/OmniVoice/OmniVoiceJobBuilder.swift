import Foundation

/// Maps a generation request onto a single-segment OmniVoice worker job.
/// `voice` is treated as a reference-audio file path for cloning when it points
/// at an existing file; otherwise cloning is skipped (plain TTS / voice design).
enum OmniVoiceJobBuilder {
    static func build(genInput: GenerationInput, outputPath: String) -> OmniVoiceJob {
        let language = genInput.language?.isEmpty == false ? genInput.language! : "English"
        let instruct = genInput.styleInstructions?.isEmpty == false ? genInput.styleInstructions : nil
        let refAudio: String? = {
            guard let v = genInput.voice, FileManager.default.fileExists(atPath: v) else { return nil }
            return v
        }()
        let segment = OmniVoiceSegment(text: genInput.prompt, output: outputPath, instruct: instruct)
        return OmniVoiceJob(refAudio: refAudio, language: language, segments: [segment])
    }
}
