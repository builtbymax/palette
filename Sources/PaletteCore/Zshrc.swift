import Foundation

/// The lines Palette adds to `~/.zshrc`.
public enum Zshrc {
    public static let begin = "# >>> palette >>>"
    public static let end = "# <<< palette <<<"

    /// `text` without Palette's block and without lines that source
    /// `script` or a `palette.zsh` inside Palette.app (copied by hand);
    /// nil when there is nothing to remove.
    public static func removingPalette(from text: String, script: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        var removed = false
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line == begin, let close = lines[i...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == end }) {
                // The install adds an empty line before the block.
                let start = i > 0 && lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty ? i - 1 : i
                lines.removeSubrange(start...close)
                i = start
                removed = true
            } else if sourcesPalette(line, script: script) {
                lines.remove(at: i)
                removed = true
            } else {
                i += 1
            }
        }
        return removed ? lines.joined(separator: "\n") : nil
    }

    private static func sourcesPalette(_ line: String, script: String) -> Bool {
        let words = line.split(separator: " ", maxSplits: 1)
        guard words.count == 2, words[0] == "source" || words[0] == "." else { return false }
        let path = words[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return path == script || path.hasSuffix("Palette.app/Contents/Resources/palette.zsh")
    }
}
