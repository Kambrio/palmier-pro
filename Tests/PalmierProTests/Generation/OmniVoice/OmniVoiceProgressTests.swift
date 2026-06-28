import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceProgress")
struct OmniVoiceProgressTests {

    @Test func parsesModelReady() throws {
        let line = #"{"status": "model_ready", "device": "mps", "num_step": 16}"#
        #expect(OmniVoiceProgress.parse(line) == .modelReady(device: "mps"))
    }

    @Test func parsesSegmentDone() throws {
        let line = #"{"segment": 2, "status": "done", "actual_duration": 3.48, "language": "English"}"#
        #expect(OmniVoiceProgress.parse(line) == .segmentDone(index: 2, durationSeconds: 3.48))
    }

    @Test func parsesSegmentCached() throws {
        let line = #"{"segment": 0, "status": "cached", "actual_duration": 1.2}"#
        #expect(OmniVoiceProgress.parse(line) == .segmentCached(index: 0, durationSeconds: 1.2))
    }

    @Test func parsesSegmentError() throws {
        let line = #"{"segment": 1, "status": "error", "error": "boom"}"#
        #expect(OmniVoiceProgress.parse(line) == .segmentError(index: 1, message: "boom"))
    }

    @Test func parsesComplete() throws {
        let line = #"{"status": "complete", "total": 5, "done": 4, "cached": 1, "errors": 0}"#
        #expect(OmniVoiceProgress.parse(line) == .complete(total: 5))
    }

    @Test func ignoresNonJSONAndUnknown() throws {
        #expect(OmniVoiceProgress.parse("loading model...") == nil)
        #expect(OmniVoiceProgress.parse("") == nil)
        #expect(OmniVoiceProgress.parse(#"{"status": "job_start", "job": 0}"#) == .other)
    }
}
