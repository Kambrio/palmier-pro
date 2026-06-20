import Foundation
import Testing
@testable import PalmierPro

@Suite("HiggsfieldCommand")
struct HiggsfieldCommandTests {

    private func input(model: String = "nano_banana_2") -> GenerationInput {
        GenerationInput(prompt: "a cat", model: model, duration: 5, aspectRatio: "16:9", resolution: "1080p")
    }

    @Test func imageArgsIncludePromptModelAspectAndJSON() {
        let argv = HiggsfieldCommand.argv(
            genInput: input(), assetType: .image, referencePaths: [], numImages: 1)
        #expect(argv.first == "generate")
        #expect(argv.contains("create"))
        #expect(argv.contains("nano_banana_2"))
        #expect(adjacent(argv, "--prompt", "a cat"))
        #expect(adjacent(argv, "--aspect_ratio", "16:9"))
        #expect(argv.contains("--wait"))
        #expect(argv.contains("--json"))
    }

    @Test func imageReferencesBecomeImageFlags() {
        let argv = HiggsfieldCommand.argv(
            genInput: input(), assetType: .image,
            referencePaths: ["/tmp/a.png", "/tmp/b.png"], numImages: 1)
        #expect(occurrences(argv, of: "--image") == 2)
        #expect(adjacent(argv, "--image", "/tmp/a.png"))
        #expect(adjacent(argv, "--image", "/tmp/b.png"))
    }

    @Test func videoUsesStartImageForFirstReference() {
        let argv = HiggsfieldCommand.argv(
            genInput: input(model: "seedance"), assetType: .video,
            referencePaths: ["/tmp/first.png"], numImages: 1)
        #expect(adjacent(argv, "--start-image", "/tmp/first.png"))
    }

    @Test func resolutionOmittedWhenNil() {
        var gi = input(); gi.resolution = nil
        let argv = HiggsfieldCommand.argv(
            genInput: gi, assetType: .image, referencePaths: [], numImages: 1)
        #expect(!argv.contains("--resolution"))
    }

    private func adjacent(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        for i in argv.indices where argv[i] == flag {
            if i + 1 < argv.count && argv[i + 1] == value { return true }
        }
        return false
    }
    private func occurrences(_ argv: [String], of flag: String) -> Int {
        argv.filter { $0 == flag }.count
    }
}
