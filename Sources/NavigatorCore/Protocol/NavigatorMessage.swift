import Foundation

/// Something the user asked for directly, rather than something an agent did.
public enum NavigatorCommand: String, Codable, Sendable, Equatable, CaseIterable {
    case repeatLast
    case status
    case catchUp
    case mute
    case unmute
    /// Speak an arbitrary string. Exists to check the audio path without
    /// waiting for an agent to do something interesting.
    case say
}

/// One message on its way to the daemon: either a hook event or a command.
public struct NavigatorRequest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let protocolVersion: Int
    /// Present for hook traffic, absent for control traffic.
    public let event: HookEvent?
    /// Stamped by the hook, not the daemon: it is closer to when the event
    /// actually happened, and it keeps the daemon's engine free of clock reads.
    public let at: Date
    public let command: NavigatorCommand?
    public let argument: String?

    public init(event: HookEvent, at: Date, protocolVersion: Int = currentVersion) {
        self.event = event
        self.at = at
        self.command = nil
        self.argument = nil
        self.protocolVersion = protocolVersion
    }

    private init(command: NavigatorCommand, argument: String?, at: Date) {
        self.event = nil
        self.at = at
        self.command = command
        self.argument = argument
        self.protocolVersion = Self.currentVersion
    }

    public static func control(
        _ command: NavigatorCommand, argument: String? = nil, at: Date
    ) -> NavigatorRequest {
        NavigatorRequest(command: command, argument: argument, at: at)
    }

    /// Nil for control traffic, which has no event to decide about.
    public var stamped: StampedEvent? {
        event.map { StampedEvent(event: $0, at: at) }
    }
}

/// What the daemon sends back.
public struct NavigatorResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    /// What the hook should print on stdout. Nil means print nothing.
    public let output: String?
    /// Human-readable text for a terminal. Never reaches Claude Code — the hook
    /// ignores it, so a chatty command reply cannot leak into a session.
    public let message: String?

    public init(
        output: String?, message: String? = nil,
        protocolVersion: Int = NavigatorRequest.currentVersion
    ) {
        self.output = output
        self.message = message
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
