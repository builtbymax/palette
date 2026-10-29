import Darwin
import Foundation

/// A private `zsh -f -i` running `worker.zsh` in its own pseudo-terminal.
///
/// Calls are blocking and must be serialised by the caller; `Completer` does
/// that. A request that exceeds its deadline kills the worker's process group;
/// the next request starts a fresh one.
public final class ZshWorker {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    private let script: String
    private let fpath: String
    private let cacheDir: String
    private let requestPath: String
    private var master: Int32 = -1
    private var pid: pid_t = 0
    /// Upper bound for one reply; a huge completion list is cut off rather than buffered.
    static let maxOutput = 32 << 20

    public init(script: String, fpath: String, cacheDir: String) {
        self.script = script
        self.fpath = fpath
        self.cacheDir = cacheDir
        requestPath = (cacheDir as NSString).appendingPathComponent("request-\(getpid())-\(UUID().uuidString.prefix(8))")
    }

    deinit { stop() }

    public func stop() {
        if pid > 0 {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            pid = 0
        }
        if master >= 0 { close(master); master = -1 }
        unlink(requestPath)
    }

    /// Completes `line` in `cwd`. Returns every candidate zsh produces for the
    /// position at the end of `line`.
    public func complete(line: String, cwd: String, path: String, snapshot: String = "", signature: String = "",
                         timeout: TimeInterval = 1.5) throws -> [Candidate] {
        try start()
        let request = "\(cwd)\n\(path)\n\(snapshot)\n\(signature)\n\(line)\n"
        guard FileManager.default.createFile(atPath: requestPath, contents: Data(request.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Failure(description: "cannot write \(requestPath)")
        }
        drain()
        do {
            try writeAll([0x07])
            let output = try read(until: 0x03, after: 0x02, timeout: timeout)
            return Candidate.parse(String(decoding: output, as: UTF8.self))
        } catch {
            stop()
            throw error
        }
    }

    private func start() throws {
        if pid > 0 {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 { return }
            pid = 0
            stop()
        }
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        guard fd >= 0, grantpt(fd) == 0, unlockpt(fd) == 0, let name = ptsname(fd) else {
            if fd >= 0 { close(fd) }
            throw Failure(description: "cannot open a pseudo-terminal")
        }
        let slave = String(cString: name)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slave, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let home = NSHomeDirectory()
        var env = [
            "HOME=\(home)",
            "USER=\(NSUserName())",
            "LOGNAME=\(NSUserName())",
            "SHELL=/bin/zsh",
            "TERM=xterm-256color",
            "LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "PALETTE_WORKER=1",
            "PALETTE_FPATH=\(fpath)",
            "PALETTE_CACHE=\(cacheDir)",
            "PALETTE_REQ=\(requestPath)",
        ]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { env.append("TMPDIR=\(tmp)") }

        let argv = ["zsh", "-f", "-i"]
        var cArgv = argv.map { strdup($0) } + [nil]
        var cEnv = env.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, "/bin/zsh", &actions, &attributes, &cArgv, &cEnv)
        guard rc == 0 else {
            close(fd)
            throw Failure(description: "cannot start zsh: \(String(cString: strerror(rc)))")
        }
        pid = child
        master = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        do {
            try writeAll(Array("source \(quoted)\n".utf8))
            _ = try read(until: 0x04, after: nil, timeout: 5)
        } catch {
            stop()
            throw error
        }
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(1)
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
            if n > 0 { offset += n; continue }
            if n < 0, errno != EAGAIN, errno != EINTR { throw Failure(description: "worker write failed") }
            if Date() > deadline { throw Failure(description: "worker write timed out") }
            var p = pollfd(fd: master, events: Int16(POLLOUT), revents: 0)
            poll(&p, 1, 50)
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while Darwin.read(master, &buffer, buffer.count) > 0 {}
    }

    /// Reads until `end` follows `start` (or until `end` when start is nil)
    /// and returns the bytes between them.
    private func read(until end: UInt8, after start: UInt8?, timeout: TimeInterval) throws -> [UInt8] {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        var begin: Int? = start == nil ? 0 : nil
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw Failure(description: "worker timed out") }
            var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min(remaining, 0.25) * 1000) + 1)
            if ready < 0, errno != EINTR { throw Failure(description: "worker poll failed") }
            if ready <= 0 { continue }
            let n = Darwin.read(master, &buffer, buffer.count)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                throw Failure(description: "worker exited")
            }
            if n < 0 { continue }
            let from = data.count
            data.append(contentsOf: buffer[0..<n])
            if data.count > Self.maxOutput { throw Failure(description: "worker output too large") }
            if begin == nil, let s = start, let i = data[from...].lastIndex(of: s) {
                begin = i + 1
            }
            if let b = begin, let e = data[max(b, from)...].firstIndex(of: end) {
                return Array(data[b..<e])
            }
        }
    }
}
