import Foundation

/// The completion request derived from the text left of the cursor.
///
/// zsh is asked to complete `line` (everything up to the `anchor`), which
/// yields every candidate for the current position. `query` — the rest of the
/// word — is then matched fuzzily by Palette instead of by zsh's prefix rules.
public struct CompletionContext: Equatable {
    /// Text sent to zsh: the buffer up to and including the anchor.
    public let line: String
    /// Leading part of the current word that zsh receives, e.g. `src/` or `-`.
    public let anchor: String
    /// Remainder of the current word, matched fuzzily.
    public let query: String
    /// True when the current word is a command name.
    public let isCommandPosition: Bool
    /// First word of the current command, used to scope learning.
    public let command: String

    public var cacheKey: String { line }

    /// Returns nil when the buffer is not something Palette should complete
    /// (multi-line input, open quotes, quoted words).
    public static func parse(_ buffer: String) -> CompletionContext? {
        let chars = Array(buffer)
        if chars.contains(where: { $0 == "\n" || $0 == "\r" }) { return nil }

        var single = false, double = false, escaped = false
        var wordStart = 0
        var words: [String] = []  // completed words of the current command
        var current = ""

        for (i, c) in chars.enumerated() {
            if escaped { escaped = false; current.append(c); continue }
            if single { if c == "'" { single = false }; current.append(c); continue }
            if c == "\\" { escaped = true; current.append(c); continue }
            if double { if c == "\"" { double = false }; current.append(c); continue }
            switch c {
            case "'": single = true; current.append(c)
            case "\"": double = true; current.append(c)
            case " ", "\t":
                if !current.isEmpty { words.append(current) }
                current = ""
                wordStart = i + 1
            case ";", "|", "&", "(", ")", "{", "}", "`":
                words = []
                current = ""
                wordStart = i + 1
            default:
                current.append(c)
            }
        }
        if single || double || escaped { return nil }

        let word = String(chars[wordStart...])
        let commandWords = words.drop(while: { isAssignment($0) })
        let isCommandPosition = commandWords.isEmpty && !isAssignment(word)

        let anchor = anchorOf(word)
        let query = String(word.dropFirst(anchor.count))
        if query.contains(where: { "'\"\\".contains($0) }) { return nil }

        let prefix = String(chars[..<wordStart])
        return CompletionContext(
            line: prefix + anchor,
            anchor: anchor,
            query: query,
            isCommandPosition: isCommandPosition,
            command: commandWords.first ?? (isCommandPosition ? "" : word)
        )
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        return word[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func anchorOf(_ word: String) -> String {
        if let i = word.lastIndex(where: { $0 == "/" || $0 == "=" }) {
            return String(word[...i])
        }
        if let first = word.first, "-$~".contains(first) {
            return String(first)
        }
        return ""
    }
}
