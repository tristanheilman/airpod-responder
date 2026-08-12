import Darwin
import Foundation
import NavigatorCore
import NavigatorIO

let home = NSHomeDirectory() as NSString
let defaultSocket = home.appendingPathComponent(".claude/navigator.sock")
let defaultLogDir = URL(fileURLWithPath: home.appendingPathComponent(".claude/navigator"))
let settingsPath = home.appendingPathComponent(".claude/settings.json")

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: navigator <command>

      run                 start the daemon in the foreground
      install [--apply]   print the hook configuration; write it with --apply
      status              report whether a daemon is listening

    The observer build never returns a decision to Claude Code. Sessions behave
    exactly as they would with no hook installed.

    """.utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }

switch arguments[1] {

case "run":
    // stdout is fully buffered when redirected to a file or pipe, which is how a
    // daemon is normally run. Without this its banner and any diagnostics sit in
    // the buffer indefinitely and the log looks empty while it is working fine.
    setvbuf(stdout, nil, _IOLBF, 0)

    let socketPath = ProcessInfo.processInfo.environment["NAVIGATOR_SOCKET"] ?? defaultSocket
    let server = NavigatorServer(
        socketPath: socketPath,
        log: DecisionLog(directory: defaultLogDir),
        config: .default,
        startingAt: Date())

    do {
        try server.start()
    } catch {
        FileHandle.standardError.write(Data("cannot listen on \(socketPath): \(error)\n".utf8))
        exit(1)
    }

    print("navigator listening on \(socketPath)")
    print("logging to \(defaultLogDir.path)")
    print("wire gate CLOSED — no decisions are returned to Claude Code")

    // DispatchSourceSignal rather than signal(): its handler runs on a normal
    // queue, where stopping the server and draining the log queue are safe.
    // A C signal handler may call almost nothing, so the obvious
    // `signal(SIGTERM) { _ in exit(0) }` would abandon in-flight log writes and
    // leave the socket file behind.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let shutdown: @Sendable () -> Void = {
        print("\nnavigator stopping — draining decision log")
        server.stop()
        exit(0)
    }

    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigint.setEventHandler(handler: shutdown)
    sigterm.setEventHandler(handler: shutdown)
    sigint.resume()
    sigterm.resume()

    dispatchMain()

case "install":
    // The hook lives beside this binary, so a built tree and an installed tree
    // both resolve correctly without configuration.
    let hookPath = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .appendingPathComponent("navigator-hook")
        .path

    if !FileManager.default.isExecutableFile(atPath: hookPath) {
        FileHandle.standardError.write(
            Data("warning: no navigator-hook beside this binary at \(hookPath)\n".utf8))
    }

    let existing = (try? Data(contentsOf: URL(fileURLWithPath: settingsPath)))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

    let merged = HookInstaller.merged(
        into: existing, hookPath: hookPath, timeoutSeconds: 5)

    let rendered = try JSONSerialization.data(
        withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

    guard arguments.contains("--apply") else {
        print("Would write to \(settingsPath):\n")
        print(String(decoding: rendered, as: UTF8.self))
        print("\nRe-run with --apply to write it.")
        exit(0)
    }

    // Back up before touching a file the user's whole CLI depends on.
    if FileManager.default.fileExists(atPath: settingsPath) {
        let backup = settingsPath + ".navigator-backup"
        try? FileManager.default.removeItem(atPath: backup)
        try FileManager.default.copyItem(atPath: settingsPath, toPath: backup)
        print("Backed up to \(backup)")
    }
    try rendered.write(to: URL(fileURLWithPath: settingsPath))
    print("Installed \(HookInstaller.observedEvents.count) hooks pointing at \(hookPath)")

case "status":
    let socketPath = ProcessInfo.processInfo.environment["NAVIGATOR_SOCKET"] ?? defaultSocket
    if let socket = try? UnixSocket.connect(to: socketPath, timeout: 0.1) {
        socket.close()
        print("daemon listening on \(socketPath)")
    } else {
        // Not an error: "no daemon" is a supported state, and hooks degrade to
        // silence when it is true.
        print("no daemon on \(socketPath) — sessions run unaffected")
    }

default:
    usage()
}
