import Foundation
import Testing
@testable import NavigatorCore

@Suite struct NavigatorMessaging {
    let event = HookEvent(
        kind: .preToolUse, sessionID: "s1", cwd: "/p",
        toolName: "Bash", toolInput: ["command": .string("swift build")])

    @Test func requestRoundTrips() throws {
        let request = NavigatorRequest(event: event, at: Date(timeIntervalSince1970: 1000))
        let line = try NavigatorMessage.encodeLine(request)
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)

        #expect(back.event == event)
        #expect(back.at == Date(timeIntervalSince1970: 1000))
        #expect(back.protocolVersion == NavigatorRequest.currentVersion)
    }

    @Test func encodedLineEndsWithExactlyOneNewline() throws {
        let request = NavigatorRequest(event: event, at: Date(timeIntervalSince1970: 1000))
        let line = try NavigatorMessage.encodeLine(request)
        let text = String(decoding: line, as: UTF8.self)

        #expect(text.hasSuffix("\n"))
        #expect(text.dropLast().contains("\n") == false, "payload must stay on one line")
    }

    @Test func responseRoundTrips() throws {
        let response = NavigatorResponse(output: "{\"a\":1}")
        let line = try NavigatorMessage.encodeLine(response)
        let back: NavigatorResponse = try NavigatorMessage.decode(line, as: NavigatorResponse.self)
        #expect(back.output == "{\"a\":1}")
    }

    @Test func emptyResponseCarriesNoOutput() throws {
        let line = try NavigatorMessage.encodeLine(NavigatorResponse.empty)
        let back: NavigatorResponse = try NavigatorMessage.decode(line, as: NavigatorResponse.self)
        #expect(back.output == nil)
    }

    @Test func decodingToleratesTrailingNewline() throws {
        let request = NavigatorRequest(event: event, at: Date(timeIntervalSince1970: 1000))
        var line = try NavigatorMessage.encodeLine(request)
        line.append(contentsOf: [0x0a])
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)
        #expect(back.event?.sessionID == "s1")
    }

    @Test func eventWithEmbeddedNewlinesStillEncodesToOneLine() throws {
        // Bash commands routinely contain newlines. If they leaked into the
        // framing, the daemon would read half a message.
        let multiline = HookEvent(
            kind: .preToolUse, sessionID: "s1", cwd: "/p", toolName: "Bash",
            toolInput: ["command": .string("git commit -m \"a\n\nb\"")])
        let line = try NavigatorMessage.encodeLine(
            NavigatorRequest(event: multiline, at: Date(timeIntervalSince1970: 0)))
        let text = String(decoding: line, as: UTF8.self)

        #expect(text.dropLast().contains("\n") == false)

        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)
        #expect(back.event?.command == "git commit -m \"a\n\nb\"")
    }
}

@Suite struct ControlMessaging {
    let t0 = Date(timeIntervalSince1970: 5)

    @Test func controlRequestRoundTrips() throws {
        let request = NavigatorRequest.control(.catchUp, at: t0)
        let line = try NavigatorMessage.encodeLine(request)
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)

        #expect(back.command == .catchUp)
        #expect(back.event == nil)
        #expect(back.stamped == nil)
    }

    @Test func controlRequestCarriesAnArgument() throws {
        let request = NavigatorRequest.control(.say, argument: "hello there", at: t0)
        let line = try NavigatorMessage.encodeLine(request)
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)

        #expect(back.argument == "hello there")
    }

    @Test func hookRequestsStillDecodeWithNoCommand() throws {
        // The installed hook binary predates control messages; its payloads must
        // keep working without a reinstall.
        let event = HookEvent(kind: .stop, sessionID: "s", cwd: "/p")
        let request = NavigatorRequest(event: event, at: t0)
        let line = try NavigatorMessage.encodeLine(request)
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)

        #expect(back.command == nil)
        #expect(back.event?.kind == .stop)
        #expect(back.stamped?.event.kind == .stop)
    }

    @Test func aPayloadFromTheOlderHookStillDecodes() throws {
        // Literal wire bytes as the shipped hook writes them, with no command or
        // argument keys at all.
        let json = #"{"at":5,"event":{"cwd":"/p","hook_event_name":"Stop","session_id":"s"},"protocolVersion":1}"#
        let back: NavigatorRequest = try NavigatorMessage.decode(
            Data(json.utf8), as: NavigatorRequest.self)

        #expect(back.event?.sessionID == "s")
        #expect(back.command == nil)
    }

    @Test func responseCarriesAMessageForTheTerminal() throws {
        let response = NavigatorResponse(output: nil, message: "2 sessions: app, homelab.")
        let line = try NavigatorMessage.encodeLine(response)
        let back: NavigatorResponse = try NavigatorMessage.decode(line, as: NavigatorResponse.self)

        #expect(back.message == "2 sessions: app, homelab.")
        #expect(back.output == nil)
    }

    @Test func everyCommandSurvivesTheWire() throws {
        for command in NavigatorCommand.allCases {
            let line = try NavigatorMessage.encodeLine(
                NavigatorRequest.control(command, at: t0))
            let back: NavigatorRequest = try NavigatorMessage.decode(
                line, as: NavigatorRequest.self)
            #expect(back.command == command)
        }
    }
}
