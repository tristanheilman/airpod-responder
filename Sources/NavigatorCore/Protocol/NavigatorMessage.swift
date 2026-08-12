import Foundation

/// One hook event on its way to the daemon.
public struct NavigatorRequest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let protocolVersion: Int
    public let event: HookEvent
    /// Stamped by the hook, not the daemon: it is closer to when the event
    /// actually happened, and it keeps the daemon's engine free of clock reads.
    public let at: Date

    public init(event: HookEvent, at: Date, protocolVersion: Int = currentVersion) {
        self.event = event
        self.at = at
        self.protocolVersion = protocolVersion
    }

    public var stamped: StampedEvent { StampedEvent(event: event, at: at) }
}

/// What the hook should print on stdout. `nil` means print nothing.
public struct NavigatorResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let output: String?

    public init(output: String?, protocolVersion: Int = NavigatorRequest.currentVersion) {
        self.output = output
        self.protocolVersion = protocolVersion
    }

    public static let empty = NavigatorResponse(output: nil)
}

/// Newline-delimited JSON, one message per line.
///
/// JSON escaping guarantees no raw newline survives inside a payload, so a bare
/// `\n` is a safe frame terminator even for bash commands full of them.
public enum NavigatorMessage {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = try encoder.encode(value)
        data.append(0x0a)
        return data
    }

    public static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Trim trailing newlines only; JSONDecoder already tolerates leading
        // whitespace. Written as a loop rather than chained drop/reversed
        // because `DropWhileSequence` is only a Sequence and has no `reversed()`.
        var bytes = Data(data)
        while bytes.last == 0x0a { bytes.removeLast() }
        return try decoder.decode(type, from: bytes)
    }
}
