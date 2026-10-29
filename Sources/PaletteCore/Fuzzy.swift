import Foundation

public struct FuzzyMatch: Equatable {
    /// 3 = prefix, 2 = substring, 1 = subsequence. Higher tiers always win.
    public var tier: Int
    public var score: Int
    /// Character offsets in the matched text, for highlighting.
    public var positions: [Int]
}

public enum Fuzzy {
    /// Smart case: a query containing uppercase letters matches case-sensitively.
    public static func match(_ query: String, in text: String) -> FuzzyMatch? {
        if query.isEmpty { return FuzzyMatch(tier: 3, score: 0, positions: []) }
        let sensitive = query.contains(where: \.isUppercase)
        let q = Array(sensitive ? query : query.lowercased())
        let t = Array(sensitive ? text : text.lowercased())
        guard q.count <= t.count else { return nil }

        if t.starts(with: q) {
            return FuzzyMatch(tier: 3, score: 1000 - t.count, positions: Array(0..<q.count))
        }
        if let start = substring(q, in: t) {
            let bonus = isBoundary(t, start) ? 200 : 0
            return FuzzyMatch(tier: 2, score: 1000 + bonus - start * 4 - t.count, positions: Array(start..<start + q.count))
        }

        // Subsequence: greedy, but jump to a word boundary when one is ahead.
        var positions: [Int] = []
        var score = 1000 - t.count
        var ti = 0
        for qc in q {
            var found: Int?
            var j = ti
            while j < t.count {
                if t[j] == qc {
                    if found == nil { found = j }
                    if isBoundary(t, j) { found = j; break }
                }
                j += 1
            }
            guard let at = found else { return nil }
            if isBoundary(t, at) { score += 30 }
            if let last = positions.last {
                score += at == last + 1 ? 20 : -min(at - last, 10)
            }
            positions.append(at)
            ti = at + 1
        }
        return FuzzyMatch(tier: 1, score: score, positions: positions)
    }

    static func substring(_ q: [Character], in t: [Character]) -> Int? {
        guard q.count <= t.count else { return nil }
        for i in 0...(t.count - q.count) where t[i] == q[0] {
            if Array(t[i..<i + q.count]) == q { return i }
        }
        return nil
    }

    static func isBoundary(_ t: [Character], _ i: Int) -> Bool {
        i == 0 || "-_./ :@".contains(t[i - 1])
    }
}

public struct Suggestion: Equatable {
    public var candidate: Candidate
    public var insertion: String
    public var replace: Int
    /// Highlight offsets into `candidate.display`.
    public var highlights: [Int]
}

public enum Ranker {
    /// Ranks candidates for the context. `boost` returns a learned weight for
    /// a candidate; it only reorders within a match tier.
    public static func rank(
        _ candidates: [Candidate],
        for context: CompletionContext,
        limit: Int = 50,
        boost: (Candidate) -> Double = { _ in 0 }
    ) -> [Suggestion] {
        struct Scored { var index: Int; var match: FuzzyMatch; var boost: Double; var group: Int; var offset: Int }
        var scored: [Scored] = []
        // zsh emits groups in a meaningful order (git's main porcelain before
        // plumbing), so a group's first appearance outranks word length. The
        // user's own aliases go first: zsh lists them after $PATH commands.
        var groups: [String: Int] = [:]
        for c in candidates where c.tag.contains("alias") && groups[c.tag] == nil { groups[c.tag] = groups.count }
        for c in candidates where groups[c.tag] == nil { groups[c.tag] = groups.count }
        let hideDotfiles = !context.query.hasPrefix(".")
        for (i, c) in candidates.enumerated() {
            if hideDotfiles, c.display.hasPrefix("."), c.tag.contains("file") || c.tag.contains("director") { continue }
            let (text, offset) = c.matchText(for: context)
            guard let m = Fuzzy.match(context.query, in: text) else { continue }
            scored.append(Scored(index: i, match: m, boost: boost(c), group: groups[c.tag] ?? 0, offset: offset))
        }
        scored.sort { a, b in
            if a.match.tier != b.match.tier { return a.match.tier > b.match.tier }
            if a.boost != b.boost { return a.boost > b.boost }
            if a.group != b.group { return a.group < b.group }
            if context.query.isEmpty == false, a.match.score != b.match.score { return a.match.score > b.match.score }
            return a.index < b.index
        }
        return scored.prefix(limit).map { s in
            let c = candidates[s.index]
            let (text, replace) = c.insertion(for: context)
            return Suggestion(candidate: c, insertion: text, replace: replace, highlights: s.match.positions.map { $0 + s.offset })
        }
    }
}
