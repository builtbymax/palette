import AppKit
import ApplicationServices
import PaletteCore

/// The `palette` command. The zsh plugin defines a `palette` function that
/// runs this binary; commands that need the running app are sent to it over
/// the socket as a `control` message.
enum CLI {
    static let usage = """
    Usage: palette <command>

      status                 show whether Palette is running and set up
      version                print the version
      open                   start Palette, or open its menu-bar app
      update                 check for updates and install them

      learned [command]      list learned suggestions, strongest first
      forget <command> [word]
                             forget a learned suggestion, or all for a command
      forget --all           forget every learned suggestion

      shells                 list connected shells
      unload                 remove Palette from this shell until it restarts
      unload <pid> | --all   remove Palette from another shell, or from all
      debug [on|off]         show or set debug logging
      log [-f]               print the log, or follow it
    """

    /// Runs `arguments` (without the program name) and returns the exit status.
    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 0
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "-h", "--help":
            print(usage)
            return 0
        case "version":
            print(Bundle.main.shortVersion)
            if let (ok, lines) = request(["version"]), ok, let running = lines.first, running != Bundle.main.shortVersion {
                print("running: \(running) (restart Palette to use \(Bundle.main.shortVersion))")
            }
            return 0
        case "open":
            return open()
        case "log":
            return log(follow: rest.contains("-f"))
        case "unload" where rest.isEmpty:
            // The shell function handles `palette unload` for its own shell.
            return fail("palette unload needs a pid or --all outside the zsh plugin")
        case "status", "update", "learned", "forget", "shells", "unload", "debug":
            guard let (ok, lines) = request([command] + rest) else {
                if command == "status" {
                    print("Palette \(Bundle.main.shortVersion) is not running. Start it with `palette open`.")
                    return 1
                }
                return fail("Palette is not running. Start it with `palette open`.")
            }
            lines.forEach { ok ? print($0) : FileHandle.standardError.write(Data("palette: \($0)\n".utf8)) }
            return ok ? 0 : 1
        default:
            return fail("unknown command \(command.debugDescription). See `palette help`.")
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("palette: \(message)\n".utf8))
        return 1
    }

    /// Sends `arguments` to the running app; nil when it isn't running.
    private static func request(_ arguments: [String]) -> (ok: Bool, lines: [String])? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard Server.withAddress(Paths.socket, { connect(fd, $0, $1) }) == 0 else { return nil }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let message = Array(Wire.line(["control"] + arguments).utf8)
        guard write(fd, message, message.count) == message.count else { return nil }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var lines: [String] = []
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return (false, lines + ["no answer from Palette. If it is an older version, update or restart it."]) }
            received.append(contentsOf: buffer[0..<n])
            while let newline = received.firstIndex(of: 0x0A) {
                let fields = Wire.fields(Substring(String(decoding: received[received.startIndex..<newline], as: UTF8.self)))
                received.removeSubrange(received.startIndex...newline)
                switch fields.first {
                case "out": lines.append(fields.count > 1 ? fields[1] : "")
                case "end": return (fields.count > 1 && fields[1] == "0", lines)
                default: break
                }
            }
        }
    }

    private static func open() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // Inside Palette.app this opens that copy; a debug build opens the installed app.
        let bundle = Bundle.main.bundleURL
        process.arguments = bundle.pathExtension == "app" ? [bundle.path] : ["-b", "dev.builtbymax.palette"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static func log(follow: Bool) -> Int32 {
        guard FileManager.default.fileExists(atPath: Paths.log.path) else { return fail("no log yet at \(Paths.log.path)") }
        let (tool, arguments) = follow ? ("/usr/bin/tail", ["tail", "-n", "50", "-F", Paths.log.path])
                                       : ("/bin/cat", ["cat", Paths.log.path])
        execv(tool, arguments.map { strdup($0) } + [nil])
        return fail("could not run \(tool)")
    }
}

extension Hub {
    /// Answers a `palette` CLI command inside the running app.
    func control(_ arguments: [String]) -> AppMessage {
        let args = Array(arguments.dropFirst())
        switch arguments.first {
        case "version":
            return .reply(ok: true, lines: [Bundle.main.shortVersion])
        case "status":
            return .reply(ok: true, lines: status())
        case "update":
            let updater = Updater.shared
            guard updater.isAvailable else { return .reply(ok: false, lines: ["this build can't update itself"]) }
            DispatchQueue.main.async { updater.checkForUpdates() }
            return .reply(ok: true, lines: ["Checking for updates. Palette shows the result in a window."])
        case "learned":
            return learned(command: args.first)
        case "forget":
            return forget(args)
        case "shells":
            return listShells()
        case "unload":
            return unload(args)
        case "debug":
            switch args.first {
            case nil: break
            case "on": Log.verbose = true
            case "off": Log.verbose = false
            default: return .reply(ok: false, lines: ["usage: palette debug [on|off]"])
            }
            return .reply(ok: true, lines: ["Debug logging is \(Log.verbose ? "on" : "off")."])
        default:
            return .reply(ok: false, lines: ["unknown command \((arguments.first ?? "").debugDescription)"])
        }
    }

    private func status() -> [String] {
        let shells = shells.count
        let updater = Updater.shared
        return [
            "Palette \(Bundle.main.shortVersion) is running.",
            "Shells:            \(shells == 1 ? "1 connected" : "\(shells) connected")",
            "Accessibility:     \(AXIsProcessTrusted() ? "granted" : "not granted")",
            "Shell integration: \(ShellIntegration.isInstalled ? "installed in \(Paths.abbreviated(ShellIntegration.zshrc.path))" : "not installed")",
            "Learn from picks:  \(learning.isEnabled ? "on" : "off") (\(learning.count) learned)",
            "Debug logging:     \(Log.verbose ? "on" : "off")",
            "Updates:           \(!updater.isAvailable ? "not available in this build" : updater.automaticallyChecks ? "checked automatically" : "checked manually")",
        ]
    }

    private func learned(command: String?) -> AppMessage {
        let picks = learning.picks(command: command)
        guard !picks.isEmpty else {
            return .reply(ok: true, lines: [command.map { "Nothing learned for \($0)." } ?? "Nothing learned yet."])
        }
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let rows = picks.map { [$0.command, $0.word, String(format: "%.1f", $0.score), date.string(from: $0.last)] }
        return .reply(ok: true, lines: table(header: ["COMMAND", "WORD", "SCORE", "LAST PICKED"], rows: rows))
    }

    private func forget(_ args: [String]) -> AppMessage {
        switch args.count {
        case 1 where args[0] == "--all":
            let count = learning.count
            learning.clear()
            return .reply(ok: true, lines: ["Forgot \(count) learned suggestion\(count == 1 ? "" : "s")."])
        case 1, 2:
            let removed = learning.forget(command: args[0], word: args.count == 2 ? args[1] : nil)
            guard removed > 0 else { return .reply(ok: false, lines: ["nothing learned for \(args.joined(separator: " "))"]) }
            return .reply(ok: true, lines: ["Forgot \(removed) learned suggestion\(removed == 1 ? "" : "s")."])
        default:
            return .reply(ok: false, lines: ["usage: palette forget <command> [word] | --all"])
        }
    }

    private func listShells() -> AppMessage {
        let shells = shells
        guard !shells.isEmpty else { return .reply(ok: true, lines: ["No shells connected."]) }
        let rows = shells.map { [String($0.pid), ($0.tty as NSString).lastPathComponent, Paths.abbreviated($0.cwd)] }
        return .reply(ok: true, lines: table(header: ["PID", "TTY", "DIRECTORY"], rows: rows))
    }

    private func unload(_ args: [String]) -> AppMessage {
        let targets: [Session]
        if args == ["--all"] {
            targets = shells
        } else if args.count == 1, let pid = Int32(args[0]) {
            targets = shells.filter { $0.pid == pid }
            guard !targets.isEmpty else { return .reply(ok: false, lines: ["no connected shell with pid \(pid)"]) }
        } else {
            return .reply(ok: false, lines: ["usage: palette unload [<pid> | --all]"])
        }
        targets.forEach { $0.unload() }
        return .reply(ok: true, lines: ["Unloading Palette from \(targets.count) shell\(targets.count == 1 ? "" : "s"). " +
                                        "A shell running a command unloads at its next prompt."])
    }

    private func table(header: [String], rows: [[String]]) -> [String] {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
        }
    }
}
