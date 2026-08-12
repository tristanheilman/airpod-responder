import Foundation
import NavigatorCore

/// Append-only JSONL, one file per day.
///
/// This is the observer build's actual product. The budget and thresholds are
/// guesses; this file is how they get replaced with numbers, so it is written
/// with an explicit seek-to-end on every record rather than buffered — a daemon
/// killed mid-session must not lose the day.
public struct DecisionLog: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func path(for day: Date) -> URL {
        directory.appendingPathComponent("decisions-\(Self.stamp(day)).jsonl")
    }

    public func append(_ record: DecisionRecord, on day: Date) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(record)
        line.append(0x0a)

        let url = path(for: day)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public static func replayable(from url: URL) throws -> [DecisionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(DecisionRecord.self, from: Data($0.utf8)) }
    }

    private static func stamp(_ day: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
