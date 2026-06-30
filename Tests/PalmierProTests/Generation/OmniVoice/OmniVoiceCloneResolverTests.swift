import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceCloneResolver")
struct OmniVoiceCloneResolverTests {

    @Test func extractArgsSeeksInputThenLimitsOutputDuration() {
        let args = OmniVoiceCloneResolver.extractArgs(
            input: URL(fileURLWithPath: "/tmp/a.mov"),
            startSeconds: 12.5,
            durationSeconds: 30.0,
            output: URL(fileURLWithPath: "/tmp/o.wav")
        )
        // -ss before -i (fast input seek), -t after -i (output duration), mono 24kHz PCM.
        let ss = args.firstIndex(of: "-ss")
        let inputIdx = args.firstIndex(of: "-i")
        let t = args.firstIndex(of: "-t")
        #expect(ss != nil && inputIdx != nil && ss! < inputIdx!)
        #expect(t != nil && t! > inputIdx!)
        #expect(args.contains("24000"))
        #expect(args.contains("pcm_s16le"))
        #expect(args.contains("-vn"))
        #expect(args.contains("-ac") && args.contains("1"))
    }

    @Test func extractArgsOmitsSeekAndDurationWhenZero() {
        let args = OmniVoiceCloneResolver.extractArgs(
            input: URL(fileURLWithPath: "/tmp/a.mov"),
            startSeconds: 0,
            durationSeconds: 0,
            output: URL(fileURLWithPath: "/tmp/o.wav")
        )
        #expect(!args.contains("-ss"))
        #expect(!args.contains("-t"))
    }
}
