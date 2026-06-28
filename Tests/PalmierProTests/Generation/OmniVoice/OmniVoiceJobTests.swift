import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceJob")
struct OmniVoiceJobTests {

    private func encodedDict(_ job: OmniVoiceJob) throws -> [String: Any] {
        let data = try JSONEncoder().encode(job)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func plainTTSOmitsRefAudio() throws {
        let job = OmniVoiceJob(
            language: "English",
            segments: [OmniVoiceSegment(text: "Hello", output: "/tmp/0.wav")]
        )
        let dict = try encodedDict(job)
        #expect(dict["language"] as? String == "English")
        #expect(dict["num_step"] as? Int == 16)
        #expect(dict["ref_audio"] == nil)
        let segs = try #require(dict["segments"] as? [[String: Any]])
        #expect(segs.count == 1)
        #expect(segs[0]["text"] as? String == "Hello")
        #expect(segs[0]["output"] as? String == "/tmp/0.wav")
        #expect(segs[0]["instruct"] == nil)
    }

    @Test func voiceCloningIncludesRefAudio() throws {
        let job = OmniVoiceJob(
            refAudio: "/refs/sabina.wav",
            language: "Spanish",
            segments: [OmniVoiceSegment(text: "Hola", output: "/tmp/0.wav")]
        )
        let dict = try encodedDict(job)
        #expect(dict["ref_audio"] as? String == "/refs/sabina.wav")
    }

    @Test func voiceDesignIncludesInstruct() throws {
        let job = OmniVoiceJob(
            language: "English",
            segments: [OmniVoiceSegment(text: "Hi", output: "/tmp/0.wav", instruct: "female, british accent")]
        )
        let dict = try encodedDict(job)
        let segs = try #require(dict["segments"] as? [[String: Any]])
        #expect(segs[0]["instruct"] as? String == "female, british accent")
    }

    @Test func customNumStep() throws {
        let job = OmniVoiceJob(
            language: "English",
            segments: [OmniVoiceSegment(text: "Hi", output: "/tmp/0.wav")],
            numStep: 32
        )
        let dict = try encodedDict(job)
        #expect(dict["num_step"] as? Int == 32)
    }
}
