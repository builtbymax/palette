import Foundation

/// One match captured from zsh's completion system.
public struct Candidate: Equatable, Hashable {
    /// The completion tag, e.g. `commands`, `files`, `heads-local`.
    public var tag: String
    /// What the user sees, e.g. `checkout` or `Sources/`.
    public var display: String
    /// The full, already quoted word zsh would insert.
    public var word: String
    public var description: String

    public init(tag: String, display: String, word: String, description: String) {
        self.tag = tag
        self.display = display
        self.word = word
        self.description = description
    }

    public var isDirectory: Bool { word.hasSuffix("/") }

    /// Parses worker output: records framed by RS (0x1E) … GS (0x1D), fields
    /// separated by US (0x1F). Bytes outside frames (terminal noise) are ignored.
    public static func parse(_ output: String) -> [Candidate] {
        var seen = Set<String>()
        var result: [Candidate] = []
        for chunk in output.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
            guard let end = chunk.firstIndex(of: "\u{1D}") else { continue }
            let f = Wire.fields(chunk[..<end])
            guard f.count >= 4, !f[2].isEmpty, seen.insert(f[2]).inserted else { continue }
            result.append(Candidate(tag: f[0], display: f[1].isEmpty ? f[2] : f[1], word: f[2], description: f[3]))
        }
        return result
    }

    /// Text to insert in place of the typed query, and how many characters
    /// (Unicode scalars, which is what multibyte zsh counts) to replace.
    public func insertion(for context: CompletionContext) -> (text: String, replace: Int) {
        let queryLength = context.query.unicodeScalars.count
        var text: String
        var replace: Int
        if !context.anchor.isEmpty, word.hasPrefix(context.anchor) {
            text = String(word.dropFirst(context.anchor.count))
            replace = queryLength
        } else {
            text = word
            replace = queryLength + context.anchor.unicodeScalars.count
        }
        if let last = text.last, !"/=:@,".contains(last) { text += " " }
        return (text, replace)
    }

    /// The part of `display` the query is matched against.
    public func matchText(for context: CompletionContext) -> (text: String, offset: Int) {
        if !context.anchor.isEmpty, display.hasPrefix(context.anchor) {
            return (String(display.dropFirst(context.anchor.count)), context.anchor.count)
        }
        return (display, 0)
    }
}
