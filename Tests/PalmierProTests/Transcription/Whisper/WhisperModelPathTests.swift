import Testing
import Foundation
@testable import PalmierPro

@MainActor
struct WhisperModelPathTests {
    // WhisperKit 1.0.0 lands assets at downloadBase/models/<repo-id>/<variant>:
    // HubApi.localRepoLocation = downloadBase/<repo.type>/<repo.id> ("models/argmaxinc/whisperkit-coreml"),
    // and WhisperKit.download appends the matched variant folder (== the repo string we pass).
    @Test func variantFolderMatchesWhisperKitLayout() {
        let base = URL(fileURLWithPath: "/tmp/WhisperModels", isDirectory: true)
        let folder = WhisperModelManager.variantFolder(base: base, repo: "openai_whisper-small")
        #expect(folder.path == "/tmp/WhisperModels/models/argmaxinc/whisperkit-coreml/openai_whisper-small")
    }

    @Test func folderForModelUsesSharedBaseAndVariantLayout() {
        let model = WhisperModelCatalog.model(id: "turbo")!
        let expected = WhisperModelManager.variantFolder(
            base: WhisperModelManager.modelsDirectory, repo: model.repo
        )
        #expect(WhisperModelManager.folder(for: model) == expected)
        #expect(WhisperModelManager.folder(for: model).lastPathComponent == model.repo)
    }

    @Test func differentReposResolveToDistinctFolders() {
        let base = URL(fileURLWithPath: "/tmp/WhisperModels", isDirectory: true)
        let a = WhisperModelManager.variantFolder(base: base, repo: "openai_whisper-small")
        let b = WhisperModelManager.variantFolder(base: base, repo: "openai_whisper-large-v3-turbo")
        #expect(a != b)
    }
}
