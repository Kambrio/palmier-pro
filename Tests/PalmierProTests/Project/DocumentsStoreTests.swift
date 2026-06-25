import Foundation
import Testing
@testable import PalmierPro

struct DocumentsStoreTests {
    @Test func appendsFormatExtensionWhenMissing() throws {
        #expect(try DocumentsStore.safeFilename("hooks", format: "md") == "hooks.md")
        #expect(try DocumentsStore.safeFilename("episode-1", format: "srt") == "episode-1.srt")
    }

    @Test func keepsExtensionWhenAlreadyPresent() throws {
        #expect(try DocumentsStore.safeFilename("notes.md", format: "md") == "notes.md")
        #expect(try DocumentsStore.safeFilename("Notes.MD", format: "md") == "Notes.MD")
    }

    @Test func rejectsPathTraversalAndSeparators() {
        for bad in ["../escape", "a/b", "a\\b", "~/secret", ".hidden", "  ", ""] {
            #expect(throws: DocumentsStore.DocError.self) {
                _ = try DocumentsStore.safeFilename(bad, format: "md")
            }
        }
    }
}
