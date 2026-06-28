import Testing
import Foundation
@testable import PalmierPro

/// Verifies SkillStore.seedBundledSkills never clobbers user/catalog skills, seeds fresh ones, and
/// refreshes a previously-seeded copy on a bundle change only when the user hasn't edited it.
struct SkillSeedingTests {
    private func tmpDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSkill(_ root: URL, _ id: String, _ text: String) {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func read(_ root: URL, _ id: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent("\(id)/SKILL.md"), encoding: .utf8)
    }

    private func skillMD(name: String, body: String) -> String {
        "---\nname: \(name)\ndescription: d\n---\n\n\(body)"
    }

    @Test func seedsFreshAndPreservesUserAndCatalogSkills() {
        let bundle = tmpDir(), dest = tmpDir()
        writeSkill(bundle, "montage-editing", skillMD(name: "Montage", body: "v1"))
        writeSkill(bundle, "story-development", skillMD(name: "Story", body: "v1"))
        // A pre-existing, non-seeded skill (user/catalog) must be left untouched.
        writeSkill(dest, "story-development", skillMD(name: "User's own", body: "MINE"))

        SkillStore.seedBundledSkills(from: bundle, into: dest, version: "1")

        #expect(read(dest, "montage-editing")?.contains("v1") == true)          // seeded fresh
        #expect(read(dest, "story-development")?.contains("MINE") == true)      // pre-existing kept
    }

    @Test func refreshesPristineButRespectsUserEdits() {
        let bundle = tmpDir(), dest = tmpDir()
        writeSkill(bundle, "montage-editing", skillMD(name: "Montage", body: "v1"))
        writeSkill(bundle, "story-development", skillMD(name: "Story", body: "v1"))
        SkillStore.seedBundledSkills(from: bundle, into: dest, version: "1")   // seeds both at v1

        // User edits one of the seeded copies; the other stays pristine.
        writeSkill(dest, "montage-editing", skillMD(name: "Montage", body: "EDITED"))

        // Bundle ships v2 for both.
        writeSkill(bundle, "montage-editing", skillMD(name: "Montage", body: "v2"))
        writeSkill(bundle, "story-development", skillMD(name: "Story", body: "v2"))
        SkillStore.seedBundledSkills(from: bundle, into: dest, version: "2")

        #expect(read(dest, "montage-editing")?.contains("EDITED") == true)   // user edit respected
        #expect(read(dest, "story-development")?.contains("v2") == true)     // pristine → refreshed
    }
}
