import Foundation
import Testing
@testable import PalmierPro

@Suite("CLILocator")
struct CLILocatorTests {

    @Test func overrideWinsWhenExecutable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("mytool")
        FileManager.default.createFile(atPath: fake.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])

        let locator = CLILocator(tool: "mytool", searchDirs: [], shellResolver: { nil })
        #expect(locator.resolve(override: fake.path) == fake.path)
    }

    @Test func findsToolInSearchDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("mytool")
        FileManager.default.createFile(atPath: fake.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])

        let locator = CLILocator(tool: "mytool", searchDirs: [dir.path], shellResolver: { nil })
        #expect(locator.resolve(override: nil) == fake.path)
    }

    @Test func fallsBackToShellResolver() {
        let locator = CLILocator(tool: "mytool", searchDirs: [],
                                 shellResolver: { "/somewhere/mytool" })
        #expect(locator.resolve(override: nil) == "/somewhere/mytool")
    }

    @Test func returnsNilWhenMissing() {
        let locator = CLILocator(tool: "nope", searchDirs: [], shellResolver: { nil })
        #expect(locator.resolve(override: nil) == nil)
    }
}
