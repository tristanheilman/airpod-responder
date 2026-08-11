import Foundation
import Testing
@testable import NavigatorCore

@Suite struct SessionRegistryBehavior {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func stamped(_ event: HookEvent, plus seconds: TimeInterval = 0) -> StampedEvent {
        StampedEvent(event: event, at: t0.addingTimeInterval(seconds))
    }

    @Test func registersSessionOnSessionStart() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))

        let session = registry.session(id: "s1")
        #expect(session?.cwd == "/a")
        #expect(session?.isActive == true)
        #expect(session?.route == nil)
    }

    @Test func capturesRouteFromFirstUserPromptOnly() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))
        registry.apply(stamped(HookEvent(
            kind: .userPromptSubmit, sessionID: "s1", cwd: "/a", prompt: "fix the parser")))
        registry.apply(stamped(HookEvent(
            kind: .userPromptSubmit, sessionID: "s1", cwd: "/a", prompt: "now do something else")))

        #expect(registry.session(id: "s1")?.route == "fix the parser")
    }

    @Test func adoptsSessionSeenMidFlight() {
        // The daemon may start after a session is already running, so any event
        // for an unknown session implicitly registers it.
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(
            kind: .preToolUse, sessionID: "s9", cwd: "/b", toolName: "Read")))

        #expect(registry.session(id: "s9")?.cwd == "/b")
        #expect(registry.session(id: "s9")?.isActive == true)
    }

    @Test func marksInactiveOnSessionEnd() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))
        registry.apply(stamped(HookEvent(kind: .sessionEnd, sessionID: "s1", cwd: "/a"), plus: 60))

        #expect(registry.session(id: "s1")?.isActive == false)
        #expect(registry.activeSessions.isEmpty)
    }

    @Test func tracksLastEventTime() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))
        registry.apply(stamped(HookEvent(kind: .stop, sessionID: "s1", cwd: "/a"), plus: 30))

        #expect(registry.session(id: "s1")?.lastEventAt == t0.addingTimeInterval(30))
        #expect(registry.session(id: "s1")?.startedAt == t0)
    }

    @Test func tracksMultipleSessionsIndependently() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s2", cwd: "/b")))
        registry.apply(stamped(HookEvent(
            kind: .userPromptSubmit, sessionID: "s2", cwd: "/b", prompt: "run tests")))

        #expect(registry.session(id: "s1")?.route == nil)
        #expect(registry.session(id: "s2")?.route == "run tests")
        #expect(registry.activeSessions.count == 2)
    }
}
