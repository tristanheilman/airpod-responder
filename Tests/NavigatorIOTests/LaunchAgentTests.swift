import Foundation
import Testing
@testable import NavigatorIO

@Suite struct LaunchAgentGeneration {
    private let plist = LaunchAgent.plist(
        programPath: "/Users/t/.claude/bin/navigator",
        logPath: "/Users/t/.claude/navigator/daemon.log")

    @Test func runsTheDaemonSubcommand() throws {
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments == ["/Users/t/.claude/bin/navigator", "run"])
    }

    @Test func startsAtLoginAndStaysUp() {
        // The whole reason this exists: a terminal window is not a supervisor.
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
    }

    @Test func throttlesRestartsSoACrashLoopIsNotARespawnStorm() {
        // KeepAlive with no throttle turns a startup failure into a tight
        // respawn loop that is unpleasant to notice and worse to stop.
        let throttle = plist["ThrottleInterval"] as? Int
        #expect(throttle != nil)
        #expect((throttle ?? 0) >= 10)
    }

    @Test func isNotDeprioritised() {
        // This sits in front of every matched tool call. Letting launchd treat
        // it as background work would add latency exactly where it is measured.
        #expect(plist["ProcessType"] as? String == "Interactive")
    }

    @Test func capturesOutputSoFailuresAreVisible() {
        #expect(plist["StandardOutPath"] as? String == "/Users/t/.claude/navigator/daemon.log")
        #expect(plist["StandardErrorPath"] as? String == "/Users/t/.claude/navigator/daemon.log")
    }

    @Test func labelIsStableAndReverseDNS() {
        #expect(plist["Label"] as? String == LaunchAgent.label)
        #expect(LaunchAgent.label.contains("."))
        // launchctl targets are built from this; a change orphans the old job.
        #expect(LaunchAgent.label == "com.airpodresponder.navigator")
    }

    @Test func serialisesToRealPlistData() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        let back = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        #expect(back?["Label"] as? String == LaunchAgent.label)
    }

    @Test func agentPathIsUnderLaunchAgents() {
        let path = LaunchAgent.plistURL(home: "/Users/t").path
        #expect(path == "/Users/t/Library/LaunchAgents/com.airpodresponder.navigator.plist")
    }

    @Test func serviceTargetIsDomainScoped() {
        // `launchctl bootout gui/501/label` — the domain matters; without it
        // launchctl operates on the wrong session and reports success anyway.
        #expect(LaunchAgent.serviceTarget(uid: 501) == "gui/501/com.airpodresponder.navigator")
        #expect(LaunchAgent.domainTarget(uid: 501) == "gui/501")
    }
}
