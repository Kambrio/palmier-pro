import Foundation
import Testing
@testable import PalmierPro

struct PackagePreservationTests {
    @Test func preservesDocumentsAcrossSafeSaveSwap() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pkgtest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("source.palmier", isDirectory: true)
        let dst = tmp.appendingPathComponent("dest.palmier", isDirectory: true)
        let docs = src.appendingPathComponent("documents", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("hooks".utf8).write(to: docs.appendingPathComponent("hooks.md"))
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        try VideoProject.copyDirectoryIfNeeded("documents", from: src, to: dst, fm: fm)

        let copied = dst.appendingPathComponent("documents/hooks.md")
        #expect(fm.fileExists(atPath: copied.path))
        #expect((try? String(contentsOf: copied, encoding: .utf8)) == "hooks")
    }

    @Test func inPlaceSaveLeavesDocumentsUntouched() throws {
        let fm = FileManager.default
        let pkg = fm.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString).palmier", isDirectory: true)
        defer { try? fm.removeItem(at: pkg) }
        let docs = pkg.appendingPathComponent("documents", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let file = docs.appendingPathComponent("a.md")
        try Data("x".utf8).write(to: file)

        // sourceURL == packageURL → no-op; must not delete the existing dir/file.
        try VideoProject.copyDirectoryIfNeeded("documents", from: pkg, to: pkg, fm: fm)

        #expect(fm.fileExists(atPath: file.path))
    }
}
