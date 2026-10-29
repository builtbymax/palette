import Foundation

enum Paths {
    static let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser

    static var socket: String {
        ProcessInfo.processInfo.environment["PALETTE_SOCKET"]
            ?? home.appendingPathComponent(".local/state/palette/palette.sock").path
    }

    static let support = home.appendingPathComponent("Library/Application Support/Palette")
    static let cache = home.appendingPathComponent("Library/Caches/Palette")
    static let log = home.appendingPathComponent("Library/Logs/Palette.log")

    /// `path` with the home directory shown as `~`.
    static func abbreviated(_ path: String) -> String {
        path == home.path || path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    /// Shell scripts ship in the app's Resources; debug builds fall back to
    /// the repository checkout.
    static func script(_ name: String) -> String {
        if let url = Bundle.main.url(forResource: name, withExtension: "zsh") { return url.path }
        return repository.appendingPathComponent("shell/\(name).zsh").path
    }

    /// Brand assets ship in the app's Resources; debug builds fall back to `assets/`.
    static func asset(_ name: String, _ ext: String) -> URL {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? repository.appendingPathComponent("assets/\(name).\(ext)")
    }

    private static var repository: URL {
        #if DEBUG
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #else
        // Release binaries must not embed the build machine's paths.
        Bundle.main.bundleURL
        #endif
    }
}

/// Creates or replaces a file readable only by the user.
func writePrivately(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    chmod(url.path, 0o600)
}

/// Housekeeping for files other runs left behind.
enum RuntimeData {
    static func clean() {
        let fm = FileManager.default
        // Shell snapshots of shells that are gone (normally removed on disconnect or exit).
        let state = URL(fileURLWithPath: Paths.socket).deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: state.path)) ?? [] {
            guard name.hasPrefix("shell-"), let pid = pid(in: name, after: "shell-"), !isAlive(pid) else { continue }
            try? fm.removeItem(at: state.appendingPathComponent(name))
        }
        // Completion requests of Palette instances that crashed.
        for name in (try? fm.contentsOfDirectory(atPath: Paths.cache.path)) ?? [] {
            guard name.hasPrefix("request-"), let pid = pid(in: name, after: "request-"), !isAlive(pid) else { continue }
            try? fm.removeItem(at: Paths.cache.appendingPathComponent(name))
        }
        // Earlier versions created these world-readable.
        for url in [Paths.log, Paths.log.appendingPathExtension("1"), Paths.support.appendingPathComponent("learning.json")] {
            chmod(url.path, 0o600)
        }
    }

    private static func pid(in name: String, after prefix: String) -> pid_t? {
        pid_t(name.dropFirst(prefix.count).prefix(while: \.isNumber))
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "palette.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Debug logging adds completion timings, typed command lines and screen
    /// geometry. It is off at every launch unless PALETTE_DEBUG is set.
    static var verbose = ProcessInfo.processInfo.environment["PALETTE_DEBUG"] != nil

    /// The log is rotated to `Palette.log.1` at this size, so at most two
    /// files of 512 KB are kept.
    static let limit: UInt64 = 512 * 1024

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if verbose { FileHandle.standardError.write(Data(line.utf8)) }
            let url = Paths.log
            if let handle = try? FileHandle(forWritingTo: url) {
                let size = handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
                if size > limit {
                    let old = url.appendingPathExtension("1")
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.moveItem(at: url, to: old)
                }
            } else {
                try? writePrivately(Data(line.utf8), to: url)
            }
        }
    }

    static func debug(_ message: @autoclosure () -> String) {
        if verbose { write(message()) }
    }
}
