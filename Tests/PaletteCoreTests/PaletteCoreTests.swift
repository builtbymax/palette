import XCTest
@testable import PaletteCore

final class ContextTests: XCTestCase {
    func testSubcommandPosition() throws {
        let c = try XCTUnwrap(CompletionContext.parse("git che"))
        XCTAssertEqual(c.line, "git ")
        XCTAssertEqual(c.query, "che")
        XCTAssertEqual(c.anchor, "")
        XCTAssertFalse(c.isCommandPosition)
        XCTAssertEqual(c.command, "git")
    }

    func testCommandPosition() throws {
        let c = try XCTUnwrap(CompletionContext.parse("FOO=1 gi"))
        XCTAssertTrue(c.isCommandPosition)
        XCTAssertEqual(c.query, "gi")
        let piped = try XCTUnwrap(CompletionContext.parse("ls | gr"))
        XCTAssertTrue(piped.isCommandPosition)
        XCTAssertEqual(piped.line, "ls | ")
    }

    func testPathAnchor() throws {
        let c = try XCTUnwrap(CompletionContext.parse("cat Sources/Pal"))
        XCTAssertEqual(c.line, "cat Sources/")
        XCTAssertEqual(c.anchor, "Sources/")
        XCTAssertEqual(c.query, "Pal")
    }

    func testOptionAnchor() throws {
        let c = try XCTUnwrap(CompletionContext.parse("git commit --am"))
        XCTAssertEqual(c.line, "git commit -")
        XCTAssertEqual(c.query, "-am")
        let eq = try XCTUnwrap(CompletionContext.parse("git log --format=on"))
        XCTAssertEqual(eq.anchor, "--format=")
        XCTAssertEqual(eq.query, "on")
    }

    func testEscapedSpaceStaysInWord() throws {
        let c = try XCTUnwrap(CompletionContext.parse("cd My\\ Dir/su"))
        XCTAssertEqual(c.anchor, "My\\ Dir/")
        XCTAssertEqual(c.query, "su")
    }

    func testRejectsUncompletable() {
        XCTAssertNil(CompletionContext.parse("echo 'open"))
        XCTAssertNil(CompletionContext.parse("for x in a\necho"))
    }
}

final class FuzzyTests: XCTestCase {
    func testTiers() {
        XCTAssertEqual(Fuzzy.match("che", in: "checkout")?.tier, 3)
        XCTAssertEqual(Fuzzy.match("out", in: "checkout")?.tier, 2)
        XCTAssertEqual(Fuzzy.match("cko", in: "checkout")?.tier, 2)
        XCTAssertEqual(Fuzzy.match("cp", in: "cherry-pick")?.tier, 1)
        XCTAssertEqual(Fuzzy.match("cp", in: "cherry-pick")?.positions, [0, 7])
        XCTAssertNil(Fuzzy.match("xyz", in: "checkout"))
    }

    func testSmartCase() {
        XCTAssertNotNil(Fuzzy.match("rea", in: "README.md"))
        XCTAssertNil(Fuzzy.match("Rea", in: "readme.md"))
    }

    func testRankingPrefersPrefixThenLearning() {
        let candidates = ["cherry-pick", "checkout", "switch", "cherry"].map {
            Candidate(tag: "commands", display: $0, word: $0, description: "")
        }
        let context = CompletionContext.parse("git ch")!
        let ranked = Ranker.rank(candidates, for: context) { $0.word == "checkout" ? 5 : 0 }
        XCTAssertEqual(ranked.map(\.candidate.word), ["checkout", "cherry", "cherry-pick", "switch"])
        XCTAssertEqual(ranked.first?.insertion, "checkout ")
        XCTAssertEqual(ranked.first?.replace, 2)
    }

    func testRankingPutsAliasesBeforeCommands() {
        let candidates = ["mp2bug", "mpicalc"].map { Candidate(tag: "commands", display: $0, word: $0, description: "") }
            + ["mp", "mpexec"].map { Candidate(tag: "aliases", display: $0, word: $0, description: "") }
        let context = CompletionContext.parse("mp")!
        XCTAssertEqual(Ranker.rank(candidates, for: context).map(\.candidate.word), ["mp", "mpexec", "mp2bug", "mpicalc"])
        let learned = Ranker.rank(candidates, for: context) { $0.word == "mpicalc" ? 3 : 0 }
        XCTAssertEqual(learned.first?.candidate.word, "mpicalc")
    }
}

final class CandidateTests: XCTestCase {
    func testParseIgnoresNoiseAndDuplicates() {
        let raw = "\u{1B}[K\u{1E}files\u{1F}Sources/\u{1F}Sources/\u{1F}\u{1D}junk\u{1E}files\u{1F}Sources/\u{1F}Sources/\u{1F}\u{1D}\u{1E}options\u{1F}-a\u{1F}-a\u{1F}all\u{1D}"
        let parsed = Candidate.parse(raw)
        XCTAssertEqual(parsed.map(\.word), ["Sources/", "-a"])
        XCTAssertEqual(parsed.last?.description, "all")
    }

    func testInsertionStripsAnchor() {
        let context = CompletionContext.parse("cat Sources/Pa")!
        let c = Candidate(tag: "files", display: "Palette/", word: "Sources/Palette/", description: "")
        XCTAssertEqual(c.insertion(for: context).text, "Palette/")
        XCTAssertEqual(c.insertion(for: context).replace, 2)

        let option = CompletionContext.parse("ls -a")!
        let o = Candidate(tag: "options", display: "-a", word: "-a", description: "")
        XCTAssertEqual(o.insertion(for: option).text, "a ")
        XCTAssertEqual(o.insertion(for: option).replace, 1)
    }
}

final class LearningTests: XCTestCase {
    func testDisabledLearningNeitherRecordsNorBoosts() {
        let learning = Learning(url: nil)
        learning.record(command: "git", word: "checkout")
        learning.isEnabled = false
        XCTAssertEqual(learning.boost(command: "git", word: "checkout"), 0)
        learning.record(command: "git", word: "switch")
        XCTAssertEqual(learning.count, 1)
    }

    func testOldPicksAreForgottenOnLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("learning-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        let learning = Learning(url: url)
        learning.record(command: "git", word: "checkout", now: start)
        learning.record(command: "git", word: "switch", now: start.addingTimeInterval(80 * 24 * 3600))
        let later = Learning(url: url, now: start.addingTimeInterval(Learning.retention + 1))
        XCTAssertEqual(later.count, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}

final class WireTests: XCTestCase {
    func testRoundTrip() {
        let line = "update\u{1F}7\u{1F}/tmp\u{1F}git ch\u{1F}3\u{1F}9\u{1F}120\u{1F}40"
        XCTAssertEqual(ShellMessage.parse(Substring(line)),
                       .update(EditorState(seq: 7, cwd: "/tmp", buffer: "git ch", row: 3, col: 9, cols: 120, lines: 40)))
        XCTAssertEqual(AppMessage.items(seq: 2, insertions: [Insertion(replace: 1, text: "a ")]).encoded,
                       "items\u{1F}2\u{1F}1\u{1F}a \n")
    }
}

final class WorkerTests: XCTestCase {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shell/worker.zsh").path

    func testCompletesWithRealZsh() throws {
        let cache = NSTemporaryDirectory() + "palette-tests"
        let worker = ZshWorker(script: Self.script, fpath: "", cacheDir: cache)
        defer { worker.stop() }
        let root = URL(fileURLWithPath: Self.script).deletingLastPathComponent().deletingLastPathComponent().path
        let path = "/usr/bin:/bin"

        let git = try worker.complete(line: "git ", cwd: root, path: path)
        XCTAssertTrue(git.contains { $0.word == "checkout" && !$0.description.isEmpty }, "\(git.prefix(5))")

        let files = try worker.complete(line: "ls ", cwd: root, path: path)
        XCTAssertTrue(files.contains { $0.word == "Sources/" })

        // The worker survives across requests and changes directory.
        let nested = try worker.complete(line: "ls ", cwd: root + "/Sources", path: path)
        XCTAssertTrue(nested.contains { $0.word == "PaletteCore/" })
    }
}

final class LayoutTests: XCTestCase {
    func testRexGridIsTopAligned() {
        // Logged Rex pane: 143x89 cells of 7x14 pt in a 1022x1268 pt surface.
        let grid = TerminalGrid(surface: CGRect(x: 4082, y: 82, width: 1022, height: 1268), cols: 143, rows: 89,
                                cell: CGSize(width: 7, height: 14), paddingX: nil, paddingY: 0)
        XCTAssertEqual(grid.rect(row: 88, col: 0).minY, 82 + 88 * 14)
        XCTAssertEqual(grid.origin.x, 4082 + 10.5)
    }

    func testPlacementShrinksBelowThenFlips() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let panel = CGSize(width: 300, height: 218)
        // Plenty of room: full height below.
        var frame = Placement.frame(anchor: CGRect(x: 100, y: 100, width: 8, height: 17), panel: panel,
                                    minimumHeight: 114, screen: screen, inset: 39)
        XCTAssertEqual(frame, CGRect(x: 61, y: 122, width: 300, height: 218))
        // Room for some rows: shorter, still below.
        frame = Placement.frame(anchor: CGRect(x: 100, y: 820, width: 8, height: 17), panel: panel,
                                minimumHeight: 114, screen: screen, inset: 39)
        XCTAssertEqual(frame.minY, 842)
        XCTAssertEqual(frame.maxY, 996)
        // Last line: above, never covering the line.
        let line = CGRect(x: 100, y: 960, width: 8, height: 17)
        frame = Placement.frame(anchor: line, panel: panel, minimumHeight: 114, screen: screen, inset: 39)
        XCTAssertEqual(frame.height, 218)
        XCTAssertLessThan(frame.maxY, line.minY)
    }
}
