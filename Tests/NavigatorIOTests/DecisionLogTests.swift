import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

@Suite struct DecisionLogging {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("navlog-\(UUID().uuidString)")
    }

    private func record(_ session: String, at: Date) -> DecisionRecord {
        DecisionRecord(
            at: at, sessionID: session, kind: .preToolUse, toolName: "Bash",
            reversibility: "reversible", route: "on-route",
            tierAssigned: .silent, delivered: .silent,
            suppressedBecause: nil, permission: .allow, reason: "reversible, on route")
    }

    @Test func createsDirectoryAndWritesOneLinePerRecord() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = DecisionLog(directory: dir)
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        try log.append(record("s1", at: day), on: day)
        try log.append(record("s2", at: day), on: day)

        let text = try String(contentsOf: log.path(for: day), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test func fileNameIsDatedForRotation() {
        let log = DecisionLog(directory: URL(fileURLWithPath: "/tmp/x"))
        let day = Date(timeIntervalSince1970: 1_770_000_000)  // 2026-02-02 UTC
        #expect(log.path(for: day).lastPathComponent == "decisions-2026-02-02.jsonl")
    }

    @Test func separateDaysGoToSeparateFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = DecisionLog(directory: dir)
        let dayOne = Date(timeIntervalSince1970: 1_770_000_000)
        let dayTwo = dayOne.addingTimeInterval(86_400)
        try log.append(record("s1", at: dayOne), on: dayOne)
        try log.append(record("s2", at: dayTwo), on: dayTwo)

        #expect(log.path(for: dayOne) != log.path(for: dayTwo))
        #expect(FileManager.default.fileExists(atPath: log.path(for: dayOne).path))
        #expect(FileManager.default.fileExists(atPath: log.path(for: dayTwo).path))
    }

    @Test func appendsRatherThanTruncating() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let day = Date(timeIntervalSince1970: 1_770_000_000)
        // A fresh DecisionLog each time simulates a daemon restart mid-day.
        try DecisionLog(directory: dir).append(record("s1", at: day), on: day)
        try DecisionLog(directory: dir).append(record("s2", at: day), on: day)

        let text = try String(
            contentsOf: DecisionLog(directory: dir).path(for: day), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test func recordsSurviveARoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = DecisionLog(directory: dir)
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        try log.append(record("s1", at: day), on: day)

        let back = try DecisionLog.replayable(from: log.path(for: day))
        #expect(back.count == 1)
        #expect(back.first?.sessionID == "s1")
        #expect(back.first?.reason == "reversible, on route")
    }

    @Test func reasonWithNewlinesStaysOnOneLine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = DecisionLog(directory: dir)
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        let nasty = DecisionRecord(
            at: day, sessionID: "s1", kind: .preToolUse, toolName: "Bash",
            reversibility: "reversible", route: "on-route",
            tierAssigned: .silent, delivered: .silent, suppressedBecause: nil,
            permission: .allow, reason: "ran:\ngit commit -m \"x\ny\"")
        try log.append(nasty, on: day)

        let text = try String(contentsOf: log.path(for: day), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)

        let back = try DecisionLog.replayable(from: log.path(for: day))
        #expect(back.first?.reason == "ran:\ngit commit -m \"x\ny\"")
    }
}
