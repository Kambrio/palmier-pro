import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceJobBuilder")
struct OmniVoiceJobBuilderTests {

    private func input(_ mutate: (inout GenerationInput) -> Void) -> GenerationInput {
        var i = GenerationInput(prompt: "Hello world", model: OmniVoiceCatalog.modelId, duration: 0, aspectRatio: "")
        mutate(&i)
        return i
    }

    @Test func plainTTSDefaultsLanguageAndOmitsRef() {
        let job = OmniVoiceJobBuilder.build(genInput: input { _ in }, outputPath: "/tmp/o.wav")
        #expect(job.language == "English")
        #expect(job.refAudio == nil)
        #expect(job.segments.count == 1)
        #expect(job.segments[0].text == "Hello world")
        #expect(job.segments[0].output == "/tmp/o.wav")
        #expect(job.segments[0].instruct == nil)
    }

    @Test func usesLanguageWhenSet() {
        let job = OmniVoiceJobBuilder.build(genInput: input { $0.language = "Spanish" }, outputPath: "/tmp/o.wav")
        #expect(job.language == "Spanish")
    }

    @Test func voiceDesignFromStyleInstructions() {
        let job = OmniVoiceJobBuilder.build(genInput: input { $0.styleInstructions = "female, british accent" }, outputPath: "/tmp/o.wav")
        #expect(job.segments[0].instruct == "female, british accent")
    }

    @Test func voiceCloningWhenVoiceIsAnExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID()).wav")
        try Data([0,1,2]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let job = OmniVoiceJobBuilder.build(genInput: input { $0.voice = tmp.path }, outputPath: "/tmp/o.wav")
        #expect(job.refAudio == tmp.path)
    }

    @Test func ignoresVoiceThatIsNotAFilePath() {
        let job = OmniVoiceJobBuilder.build(genInput: input { $0.voice = "narrator" }, outputPath: "/tmp/o.wav")
        #expect(job.refAudio == nil)
    }
}
