import Testing
@testable import PalmierPro

struct WhisperModelCatalogTests {
    @Test func hasTiersWithUniqueIds() {
        let ids = WhisperModelCatalog.all.map(\.id)
        #expect(ids.count >= 3)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyModelHasNonEmptyRepoAndName() {
        for m in WhisperModelCatalog.all {
            #expect(!m.repo.isEmpty)
            #expect(!m.displayName.isEmpty)
            #expect(m.approxBytes > 0)
        }
    }

    @Test func defaultIsTurboAndInCatalog() {
        #expect(WhisperModelCatalog.all.contains { $0.id == WhisperModelCatalog.defaultModelId })
        #expect(WhisperModelCatalog.defaultModelId == "turbo")
    }

    @Test func languagesIncludeRussian() {
        #expect(WhisperModelCatalog.languages.contains("ru"))
        #expect(WhisperModelCatalog.languages.contains("en"))
    }
}
