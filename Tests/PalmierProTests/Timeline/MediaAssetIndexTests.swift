import Foundation
import Testing
@testable import PalmierPro

@Suite("EditorViewModel — media asset index")
@MainActor
struct MediaAssetIndexTests {

    private func asset(_ id: String, name: String? = nil) -> MediaAsset {
        MediaAsset(id: id, url: URL(fileURLWithPath: "/tmp/\(id).mov"), type: .video, name: name ?? id, duration: 3)
    }

    private func clip(ref: String) -> Clip {
        Clip(mediaRef: ref, startFrame: 0, durationFrames: 30)
    }

    @Test func indexMatchesLibraryAfterImport() {
        let editor = EditorViewModel()
        let a = asset("a"), b = asset("b")
        editor.importMediaAsset(a)
        editor.importMediaAsset(b)
        #expect(editor.mediaAssetsById["a"] === a)
        #expect(editor.mediaAssetsById["b"] === b)
        #expect(editor.mediaAssetsById.count == 2)
    }

    @Test func indexDropsRemovedAssets() {
        let editor = EditorViewModel()
        editor.importMediaAsset(asset("a"))
        editor.mediaAssets.removeAll { $0.id == "a" }
        #expect(editor.mediaAssetsById["a"] == nil)
    }

    // The index stores object references, so generation-state changes on an existing
    // asset are reflected without rebuilding — the property mutation needs no re-append.
    @Test func generatingStateReflectedLive() {
        let editor = EditorViewModel()
        let a = asset("a")
        editor.importMediaAsset(a)
        let c = clip(ref: "a")
        #expect(editor.isClipMediaGenerating(c) == false)
        a.generationStatus = .generating
        #expect(editor.isClipMediaGenerating(c) == true)
    }

    @Test func displayLabelUsesAssetNameWhileGenerating() {
        let editor = EditorViewModel()
        let a = asset("a", name: "Clip A")
        a.generationStatus = .generating
        editor.importMediaAsset(a)
        #expect(editor.clipDisplayLabel(for: clip(ref: "a")) == "Clip A")
    }

    // The O(1) index must agree with the old linear scan for every id.
    @Test func indexLookupEqualsLinearScan() {
        let editor = EditorViewModel()
        for i in 0..<20 { editor.importMediaAsset(asset("id\(i)")) }
        for i in 0..<20 {
            let scan = editor.mediaAssets.first(where: { $0.id == "id\(i)" })
            #expect(editor.mediaAssetsById["id\(i)"] === scan)
        }
    }
}
