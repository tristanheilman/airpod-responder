import Darwin
import Foundation
import NavigatorCore
import NavigatorIO

// The single most important property of this program: it exits 0 on every path.
//
// Claude Code treats exit code 2 as a *blocking* error that stops the tool call,
// and any other non-zero as a non-blocking error. Since a notification tool must
// never be able to stop your work, there is exactly one exit call in this file.
func finish(printing output: String?) -> Never {
    if let output, !output.isEmpty {
        FileHandle.standardOutput.write(Data((output + "\n").utf8))
    }
    exit(0)
}

let environment = ProcessInfo.processInfo.environment

let socketPath = environment["NAVIGATOR_SOCKET"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude/navigator.sock")

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let event = try? JSONDecoder().decode(HookEvent.self, from: input) else {
    // Unrecognised or unparseable payload — including event kinds this build
    // does not model. Say nothing and get out of the way.
    finish(printing: nil)
}

// 250ms is the deadline for the silent majority: the daemon answers those in
// under a millisecond, and anything slower is a daemon worth giving up on.
// PermissionRequest is the one event the daemon deliberately holds while you
// decide, so it alone gets a deadline longer than the daemon's own 20s hold
// and shorter than Claude Code's 30s hook timeout. Daemon < hook < Claude Code.
// Two overrides, because they tune different things: a stray short
// NAVIGATOR_DEADLINE_MS left over from testing must not turn every question
// into an instant escalation.
let deadlineMS: Int = event.kind == .permissionRequest
    ? environment["NAVIGATOR_QUESTION_DEADLINE_MS"].flatMap(Int.init) ?? 25_000
    : environment["NAVIGATOR_DEADLINE_MS"].flatMap(Int.init) ?? 250
let deadline = TimeInterval(deadlineMS) / 1000

let request = NavigatorRequest(event: event, at: Date())

guard let line = try? NavigatorMessage.encodeLine(request) else {
    finish(printing: nil)
}

// Connect timeout is tight on purpose: for AF_UNIX this either succeeds
// immediately or fails immediately, and "no daemon" is the expected steady state
// rather than an error worth waiting on.
guard let socket = try? UnixSocket.connect(to: socketPath, timeout: 0.05) else {
    finish(printing: nil)
}
defer { socket.close() }

guard (try? socket.write(line)) != nil,
      let reply = try? socket.readLine(deadline: deadline),
      let response = try? NavigatorMessage.decode(reply, as: NavigatorResponse.self)
else {
    // Wedged or dead daemon. The hook enforces its own deadline rather than
    // trusting the daemon or Claude Code's much longer hook timeout.
    finish(printing: nil)
}

finish(printing: response.output)
