import Foundation
import Testing
@testable import NavigatorIO

@Suite struct BinaryStaging {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("navbin-\(label)-\(UUID().uuidString)")
    }

    private func makeFakeBinary(_ name: String, in dir: URL, contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func copiesBinariesAndReturnsTheirNewPaths() throws {
        let source = tempDir("src"), dest = tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        _ = try makeFakeBinary("navigator", in: source, contents: "a")
        _ = try makeFakeBinary("navigator-hook", in: source, contents: "b")

        let staged = try BinaryInstaller.stage(
            names: ["navigator", "navigator-hook"], from: source, to: dest)

        #expect(staged["navigator-hook"] == dest.appendingPathComponent("navigator-hook"))
        #expect(FileManager.default.isExecutableFile(
            atPath: dest.appendingPathComponent("navigator-hook").path))
        #expect(FileManager.default.isExecutableFile(
            atPath: dest.appendingPathComponent("navigator").path))
    }

    @Test func createsTheDestinationDirectory() throws {
        let source = tempDir("src"), dest = tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        _ = try makeFakeBinary("navigator", in: source, contents: "a")

        #expect(!FileManager.default.fileExists(atPath: dest.path))
        _ = try BinaryInstaller.stage(names: ["navigator"], from: source, to: dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func overwritesAnOlderInstall() throws {
        // Reinstalling after a rebuild is the common case, and the destination
        // may be a running binary's inode — remove before copying.
        let source = tempDir("src"), dest = tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        _ = try makeFakeBinary("navigator", in: source, contents: "old")
        _ = try BinaryInstaller.stage(names: ["navigator"], from: source, to: dest)

        _ = try makeFakeBinary("navigator", in: source, contents: "new")
        _ = try BinaryInstaller.stage(names: ["navigator"], from: source, to: dest)

        let text = try String(
            contentsOf: dest.appendingPathComponent("navigator"), encoding: .utf8)
        #expect(text == "new")
    }

    @Test func stagingOntoItselfIsANoOpRatherThanAnError() throws {
        // `navigator install` run from ~/.claude/bin would otherwise try to copy
        // a file over itself and fail.
        let dir = tempDir("same")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeFakeBinary("navigator", in: dir, contents: "same")

        let staged = try BinaryInstaller.stage(names: ["navigator"], from: dir, to: dir)

        #expect(staged["navigator"] == dir.appendingPathComponent("navigator"))
        let text = try String(
            contentsOf: dir.appendingPathComponent("navigator"), encoding: .utf8)
        #expect(text == "same")
    }

    @Test func reportsAMissingSourceBinary() throws {
        let source = tempDir("src"), dest = tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        #expect(throws: BinaryInstaller.Failure.missing("navigator-hook")) {
            try BinaryInstaller.stage(names: ["navigator-hook"], from: source, to: dest)
        }
    }
}
