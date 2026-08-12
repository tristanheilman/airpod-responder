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
        #expect(back.event.sessionID == "s1")
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
        #expect(back.event.command == "git commit -m \"a\n\nb\"")
    }
}
