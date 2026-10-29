import Foundation

/// Line protocol between the zsh plugin and the app.
///
/// One message per line; fields are separated by the ASCII unit separator
/// (0x1F). Buffers containing newlines are never completed, so no escaping is
/// needed.
public enum Wire {
    public static let separator: Character = "\u{1F}"

    public static func fields(_ line: Substring) -> [String] {
        line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    }

    public static func line(_ fields: [String]) -> String {
        fields.map { $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{1F}", with: " ") }
            .joined(separator: String(separator)) + "\n"
    }
}

public struct EditorState: Equatable {
    public var seq: Int
    public var cwd: String
    public var buffer: String
    /// Zero-based terminal cell of the cursor, or -1 when unknown.
    public var row: Int
    public var col: Int
    public var cols: Int
    public var lines: Int

    public init(seq: Int, cwd: String, buffer: String, row: Int, col: Int, cols: Int, lines: Int) {
        self.seq = seq
        self.cwd = cwd
        self.buffer = buffer
        self.row = row
        self.col = col
        self.cols = cols
        self.lines = lines
    }
}

/// Messages sent by the shell.
public enum ShellMessage: Equatable {
    case hello(pid: Int32, tty: String, fpath: String)
    case environment(path: String)
    /// A zsh script recreating the shell's aliases, completion functions,
    /// `compdef`s and styles for the worker; `signature` changes with it.
    case snapshot(path: String, signature: String)
    case update(EditorState)
    case select(Int)
    case accept(String)
    case dismiss
    case hide

    public static func parse(_ line: Substring) -> ShellMessage? {
        let f = Wire.fields(line)
        switch (f.first, f.count) {
        case ("hello", 4...):
            guard let pid = Int32(f[1]) else { return nil }
            return .hello(pid: pid, tty: f[2], fpath: f[3])
        case ("env", 2...):
            return .environment(path: f[1])
        case ("snapshot", 3...):
            return .snapshot(path: f[1], signature: f[2])
        case ("update", 8...):
            guard let seq = Int(f[1]), let row = Int(f[4]), let col = Int(f[5]),
                  let cols = Int(f[6]), let lines = Int(f[7]) else { return nil }
            return .update(EditorState(seq: seq, cwd: f[2], buffer: f[3], row: row, col: col, cols: cols, lines: lines))
        case ("select", 2...):
            return Int(f[1]).map { .select($0) }
        case ("accept", 2...):
            return .accept(f[1])
        case ("dismiss", _):
            return .dismiss
        case ("hide", _):
            return .hide
        default:
            return nil
        }
    }
}

public struct Insertion: Equatable {
    public var replace: Int
    public var text: String
    public init(replace: Int, text: String) { self.replace = replace; self.text = text }
}

/// Messages sent to the shell.
public enum AppMessage: Equatable {
    /// Suggestions for `seq`. Accepting one replaces `replace` characters
    /// before the cursor with `text`.
    case items(seq: Int, insertions: [Insertion])
    /// Nothing to show for `seq`.
    case none(seq: Int)
    /// The user clicked a row.
    case pick(seq: Int, index: Int)
    /// The app hid the panel on its own (focus loss, click elsewhere).
    case closed

    public var encoded: String {
        switch self {
        case let .items(seq, insertions):
            return Wire.line(["items", String(seq)] + insertions.flatMap { [String($0.replace), $0.text] })
        case let .none(seq):
            return Wire.line(["none", String(seq)])
        case let .pick(seq, index):
            return Wire.line(["pick", String(seq), String(index)])
        case .closed:
            return Wire.line(["closed"])
        }
    }
}
