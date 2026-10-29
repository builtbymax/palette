import Foundation

/// Remembers accepted suggestions per command, so frequent and recent picks
/// rise within their match tier. Stored as a small JSON file readable only by
/// the user. Picks unused for `retention` are forgotten.
public final class Learning {
    struct Entry: Codable {
        var count: Double
        var last: Date
    }

    private var entries: [String: Entry] = [:]
    private let url: URL?
    private let halfLife: TimeInterval = 14 * 24 * 3600
    private let capacity = 5000
    public static let retention: TimeInterval = 90 * 24 * 3600

    /// When false, picks are neither recorded nor used for ranking.
    public var isEnabled = true

    public init(url: URL?, now: Date = Date()) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
            if prune(now: now) { save() }
        }
    }

    static func key(_ command: String, _ word: String) -> String { command + "\u{1F}" + word }

    public func boost(command: String, word: String, now: Date = Date()) -> Double {
        guard isEnabled, let e = entries[Self.key(command, word)] else { return 0 }
        return e.count * pow(0.5, now.timeIntervalSince(e.last) / halfLife)
    }

    public func record(command: String, word: String, now: Date = Date()) {
        guard isEnabled else { return }
        let key = Self.key(command, word)
        let current = boost(command: command, word: word, now: now)
        entries[key] = Entry(count: current + 1, last: now)
        prune(now: now)
        if entries.count > capacity {
            let oldest = entries.sorted { $0.value.last < $1.value.last }.prefix(entries.count - capacity)
            oldest.forEach { entries.removeValue(forKey: $0.key) }
        }
        save()
    }

    public func clear() {
        entries = [:]
        save()
    }

    public var count: Int { entries.count }

    /// Drops entries older than `retention`. Returns whether any were dropped.
    @discardableResult
    private func prune(now: Date) -> Bool {
        let before = entries.count
        entries = entries.filter { now.timeIntervalSince($0.value.last) < Self.retention }
        return entries.count != before
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
        }
    }
}
