import Foundation

/// The macOS LaunchAgent that keeps the daemon running.
///
/// A terminal window is not a supervisor. Anything started from a shell dies
/// with that shell's process group — which is exactly what happened when this
/// was first attempted with `nohup` and a background job. launchd owns the
/// process instead, so it survives logout, reboot, and closing the window.
public enum LaunchAgent {
    /// launchctl targets are built from this string. Changing it orphans any
    /// previously installed job rather than replacing it.
    public static let label = "com.airpodresponder.navigator"

    public static func plistURL(home: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    /// `gui/<uid>` — the per-user GUI domain.
    public static func domainTarget(uid: uid_t) -> String { "gui/\(uid)" }

    /// `gui/<uid>/<label>` — a specific service within it.
    ///
    /// launchctl needs the domain: without it, subcommands operate on the wrong
    /// session and frequently report success while doing nothing.
    public static func serviceTarget(uid: uid_t) -> String {
        "\(domainTarget(uid: uid))/\(label)"
    }

    public static func plist(programPath: String, logPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [programPath, "run"],
            "RunAtLoad": true,
            // launchd restarts it if it dies for any reason. That is the point.
            "KeepAlive": true,
            // Without a throttle, a daemon that fails at startup respawns as
            // fast as launchd can fork it.
            "ThrottleInterval": 10,
            // This answers on the critical path of every matched tool call.
            // Background process types get deprioritised, which would show up
            // directly in the latency the end-to-end test pins.
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }
}
