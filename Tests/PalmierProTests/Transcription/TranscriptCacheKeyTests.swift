import Testing
import Foundation
@testable import PalmierPro

struct TranscriptCacheKeyTests {
    @Test func differentEngineTagYieldsDifferentKey() {
        let appleKey = TranscriptCache.cacheKeyComponent(engineTag: "apple")
        let whisperKey = TranscriptCache.cacheKeyComponent(engineTag: "whisper-turbo")
        #expect(appleKey != whisperKey)
    }

    @Test func sameEngineTagYieldsStableKey() {
        #expect(TranscriptCache.cacheKeyComponent(engineTag: "apple")
              == TranscriptCache.cacheKeyComponent(engineTag: "apple"))
    }
}
