import Darwin
import Foundation
import NavigatorAudio
import NavigatorCore
import NavigatorIO

let home = NSHomeDirectory() as NSString
let defaultSocket = home.appendingPathComponent(".claude/navigator.sock")
let defaultLogDir = URL(fileURLWithPath: home.appendingPathComponent(".claude/navigator"))
let settingsPath = home.appendingPathComponent(".claude/settings.json")
let configPath = defaultLogDir.appendingPathComponent("config.json")

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: navigator <command>

    daemon
      run                   start the daemon in the foreground
      status                report whether a daemon is listening
      service install       keep it running via launchd (starts at login)
              [--apply]     prints the job and changes nothing without this
      service restart       restart the launchd job
      service uninstall     remove the launchd job
      service status        whether launchd has it, and whether it answers

    listening
      repeat                say the last thing you were told again
      catch-up              everything since you last asked
      sessions              what every live session is doing
      say <text>            speak something, to check the audio path
      audio [--speak]       report audio devices and whether it would be
                            suppressed; --speak also plays a test phrase
      mute / unmute         stop and start talking

    setup
      install [--apply]     copy binaries to a stable prefix and register hooks
              [--prefix P]  where to copy them (default ~/.claude/bin)
      uninstall [--apply]   remove this tool's hooks from settings.json
      config [--write]      show the live settings; --write creates the file

    install and uninstall print what they would do and change nothing without
    --apply. install backs settings.json up first.

    The observer build never returns a decision to Claude Code. Sessions behave
    exactly as they would with no hook installed.

    """.utf8))
    exit(2)
}

/// Runs launchctl and returns (status, combined output).
@discardableResult
func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do { try process.run() } catch { return (-1, "cannot run launchctl: \(error)") }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Sends a control command to a running daemon and prints its reply.
func sendControl(_ command: NavigatorCommand, argument: String? = nil) -> Never {
    let socketPath = ProcessInfo.processInfo.environment["NAVIGATOR_SOCKET"] ?? defaultSocket

    guard let socket = try? UnixSocket.connect(to: socketPath, timeout: 0.5) else {
        print("no daemon on \(socketPath) — start one with: navigator run")
        exit(1)
    }
    defer { socket.close() }

    let request = NavigatorRequest.control(command, argument: argument, at: Date())
    guard let line = try? NavigatorMessage.encodeLine(request),
          (try? socket.write(line)) != nil,
          let reply = try? socket.readLine(deadline: 5),
          let response = try? NavigatorMessage.decode(reply, as: NavigatorResponse.self)
    else {
        print("daemon did not answer")
        exit(1)
    }

    print(response.message ?? "")
    exit(0)
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
    let config = ConfigFile.load(from: configPath)
    let server = NavigatorServer(
        socketPath: socketPath,
        log: DecisionLog(directory: defaultLogDir),
        config: config,
        speaker: SystemSpeaker(),
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
    // Print the live numbers, not the compiled-in ones: the whole point of the
    // config file is that these change, and a banner showing defaults while the
    // daemon runs on something else is worse than no banner.
    print(ConfigFile.describe(config))

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
    let apply = arguments.contains("--apply")

    // Where the binaries end up. Anywhere inside .build/ is unusable for a
    // persistent install: `swift package clean` deletes it and every rebuild
    // replaces it, and a hook command that no longer exists fails quietly.
    let prefix: URL = {
        if let index = arguments.firstIndex(of: "--prefix"), index + 1 < arguments.count {
            return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: home.appendingPathComponent(".claude/bin"))
    }()

    let sourceDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()

    let hookPath = prefix.appendingPathComponent("navigator-hook").path

    let existing = (try? Data(contentsOf: URL(fileURLWithPath: settingsPath)))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

    let merged = HookInstaller.merged(
        into: existing, hookPath: hookPath, timeoutSeconds: 5)

    let rendered = try JSONSerialization.data(
        withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

    guard apply else {
        print("Would copy from \(sourceDir.path):")
        print("  navigator      -> \(prefix.path)/navigator")
        print("  navigator-hook -> \(hookPath)")
        if sourceDir.path.contains("/.build/") {
            print("""

                Note: this is a build-tree binary. Installing copies it to the
                prefix above, so cleaning or rebuilding the project will not
                break the installed hook.
                """)
        }
        print("\nWould write to \(settingsPath):\n")
        print(String(decoding: rendered, as: UTF8.self))
        print("\nRe-run with --apply to write it.")
        exit(0)
    }

    do {
        try BinaryInstaller.stage(
            names: ["navigator", "navigator-hook"], from: sourceDir, to: prefix)
    } catch {
        FileHandle.standardError.write(
            Data("cannot stage binaries from \(sourceDir.path): \(error)\n".utf8))
        exit(1)
    }
    print("Copied binaries to \(prefix.path)")

    // Back up before touching a file the user's whole CLI depends on.
    if FileManager.default.fileExists(atPath: settingsPath) {
        let backup = settingsPath + ".navigator-backup"
        try? FileManager.default.removeItem(atPath: backup)
        try FileManager.default.copyItem(atPath: settingsPath, toPath: backup)
        print("Backed up settings to \(backup)")
    }
    try rendered.write(to: URL(fileURLWithPath: settingsPath))
    print("Installed \(HookInstaller.observedEvents.count) hooks pointing at \(hookPath)")
    print("\nStart it with:  \(prefix.path)/navigator run")

case "uninstall":
    // Removing hooks matters more than adding them: a settings file left
    // pointing at a deleted binary is the failure mode this whole prefix dance
    // exists to avoid.
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
          var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        print("no settings file at \(settingsPath) — nothing to remove")
        exit(0)
    }

    let removed = HookInstaller.removed(
        from: settings, matching: "navigator-hook")
    settings = removed.settings

    let rendered = try JSONSerialization.data(
        withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

    guard arguments.contains("--apply") else {
        print("Would remove \(removed.count) navigator hook entries from \(settingsPath).")
        print("Re-run with --apply to write it.")
        exit(0)
    }

    try rendered.write(to: URL(fileURLWithPath: settingsPath))
    print("Removed \(removed.count) navigator hook entries from \(settingsPath)")

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

case "service":
    let uid = getuid()
    let plistURL = LaunchAgent.plistURL(home: home as String)
    let action = arguments.count >= 3 ? arguments[2] : "status"

    switch action {
    case "install":
        let programPath = URL(fileURLWithPath: home.appendingPathComponent(".claude/bin/navigator"))
        guard FileManager.default.isExecutableFile(atPath: programPath.path) else {
            FileHandle.standardError.write(Data("""
                no installed binary at \(programPath.path)
                run `navigator install --apply` first — launchd needs a stable path,
                not one inside .build/
                """.utf8))
            exit(1)
        }

        let contents = LaunchAgent.plist(
            programPath: programPath.path,
            logPath: defaultLogDir.appendingPathComponent("daemon.log").path)

        guard arguments.contains("--apply") else {
            let data = try PropertyListSerialization.data(
                fromPropertyList: contents, format: .xml, options: 0)
            print("Would write \(plistURL.path):\n")
            print(String(decoding: data, as: UTF8.self))
            print("then: launchctl bootstrap \(LaunchAgent.domainTarget(uid: uid)) \(plistURL.path)")
            print("\nRe-run with --apply to do it.")
            exit(0)
        }

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: defaultLogDir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: plistURL)

        // Replacing an existing job: bootout first, ignoring the failure when
        // nothing was loaded, because bootstrap refuses a duplicate label.
        launchctl(["bootout", LaunchAgent.serviceTarget(uid: uid)])
        let result = launchctl(
            ["bootstrap", LaunchAgent.domainTarget(uid: uid), plistURL.path])
        guard result.status == 0 else {
            FileHandle.standardError.write(
                Data("launchctl bootstrap failed (\(result.status)): \(result.output)\n".utf8))
            exit(1)
        }
        print("Installed \(LaunchAgent.label)")
        print("It starts at login and restarts if it dies.")
        print("Logs: \(defaultLogDir.appendingPathComponent("daemon.log").path)")

    case "uninstall":
        launchctl(["bootout", LaunchAgent.serviceTarget(uid: uid)])
        try? FileManager.default.removeItem(at: plistURL)
        print("Removed \(LaunchAgent.label)")

    case "restart":
        // -k kills the running instance first; without it kickstart is a no-op
        // on an already-running job, which is exactly when you want a restart.
        let result = launchctl(["kickstart", "-k", LaunchAgent.serviceTarget(uid: uid)])
        guard result.status == 0 else {
            FileHandle.standardError.write(
                Data("not loaded? \(result.output)\nTry: navigator service install --apply\n".utf8))
            exit(1)
        }
        print("Restarted \(LaunchAgent.label)")

    case "status":
        let loaded = launchctl(["print", LaunchAgent.serviceTarget(uid: uid)])
        if loaded.status == 0 {
            let pid = loaded.output
                .split(separator: "\n")
                .first { $0.contains("pid = ") }?
                .trimmingCharacters(in: .whitespaces) ?? "loaded"
            print("launchd job loaded — \(pid)")
        } else {
            print("launchd job not loaded")
            print("install it with: navigator service install --apply")
        }
        // The socket is the truth about whether it is actually serving.
        let socketPath = ProcessInfo.processInfo.environment["NAVIGATOR_SOCKET"] ?? defaultSocket
        if let socket = try? UnixSocket.connect(to: socketPath, timeout: 0.2) {
            socket.close()
            print("daemon answering on \(socketPath)")
        } else {
            print("nothing answering on \(socketPath)")
        }

    default:
        FileHandle.standardError.write(
            Data("usage: navigator service install|uninstall|restart|status\n".utf8))
        exit(2)
    }

case "audio":
    let report = InputDeviceMonitor.report()
    print("output device   \(report.outputName ?? "none")")
    print("input device    \(report.inputName ?? "none")")

    switch report.inputInUse {
    case nil:
        print("input in use    cannot tell (no input device, or the query failed)")
    case true?:
        print("input in use    YES")
    case false?:
        print("input in use    no")
    }

    print("would speak     \(report.willSpeak ? "yes" : "NO — audio is being suppressed")")

    if report.inputInUse == true {
        print("""

            If nothing is actually using your microphone, this is a false
            positive and the tool will stay silent for as long as it lasts.
            Report the device name above — the suppression check needs to
            distinguish 'connected' from 'recording' on this hardware.
            """)
    }

    if arguments.contains("--speak") {
        // Deliberately not routed through the daemon: this checks the audio
        // path itself, so it must not be suppressed by anything.
        SystemSpeaker().say("Audio check. If you can hear this, output works.")
        Thread.sleep(forTimeInterval: 3)
    }

case "repeat":   sendControl(.repeatLast)
case "catch-up": sendControl(.catchUp)
case "sessions": sendControl(.status)
case "mute":     sendControl(.mute)
case "unmute":   sendControl(.unmute)
case "say":      sendControl(.say, argument: arguments.dropFirst(2).joined(separator: " "))

case "config":
    let config = ConfigFile.load(from: configPath)
    let exists = FileManager.default.fileExists(atPath: configPath.path)
    print("config: \(configPath.path)\(exists ? "" : "  (absent — using defaults)")")
    print(ConfigFile.describe(config))

    if arguments.contains("--write") {
        try ConfigFile.write(config, to: configPath)
        print("\nwrote \(configPath.path)")
        print("edit it, then restart the daemon for the change to take effect")
    } else if !exists {
        print("\nrun with --write to create it, then edit the numbers")
    }

default:
    usage()
}
