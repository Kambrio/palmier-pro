import Foundation
import Testing
@testable import PalmierPro

@Suite("HiggsfieldResult")
struct HiggsfieldResultTests {

    @Test func parsesCdnUrl() throws {
        let json = #"{"cdn_url":"https://cdn.higgsfield.ai/out/abc.jpg"}"#
        let urls = try HiggsfieldResult.resultURLs(fromJSON: json)
        #expect(urls == ["https://cdn.higgsfield.ai/out/abc.jpg"])
    }

    @Test func parsesResultsArray() throws {
        let json = #"{"results":[{"url":"https://x/1.mp4"},{"url":"https://x/2.mp4"}]}"#
        let urls = try HiggsfieldResult.resultURLs(fromJSON: json)
        #expect(urls == ["https://x/1.mp4", "https://x/2.mp4"])
    }

    @Test func throwsWhenNoURL() {
        #expect(throws: (any Error).self) {
            _ = try HiggsfieldResult.resultURLs(fromJSON: #"{"status":"ok"}"#)
        }
    }

    @Test func detectsResultIsInput() {
        let url = "https://cdn.higgsfield.ai/abcd1234_resize.jpg"
        #expect(HiggsfieldResult.isInputReference(url, inputUUIDs: ["abcd1234"]))
        #expect(!HiggsfieldResult.isInputReference(url, inputUUIDs: ["zzzz"]))
    }
}
