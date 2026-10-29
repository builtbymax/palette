import Foundation
import PaletteCore

/// What a session asks the UI to do. The app uses the native panel; tests
/// use a headless presenter that prints events.
protocol Presenter: AnyObject {
    func show(_ suggestions: [Suggestion], selected: Int, state: EditorState, alignCols: Int, tty: String, owner: Session)
    func select(_ index: Int, owner: Session)
    func hide(owner: Session)
}

/// Runs a session's completion requests one at a time on its own worker.
final class Completer {
    private let queue = DispatchQueue(label: "palette.completer")
    private let worker: ZshWorker

    init(fpath: String) {
        worker = ZshWorker(script: Paths.script("worker"), fpath: fpath, cacheDir: Paths.cache.path)
    }

    func complete(line: String, cwd: String, path: String, snapshot: (path: String, signature: String),
                  done: @escaping (Result<[Candidate], Error>) -> Void) {
        queue.async { [worker] in
            let started = Date()
            let result = Result {
                try worker.complete(line: line, cwd: cwd, path: path, snapshot: snapshot.path, signature: snapshot.signature)
            }
            Log.debug("complete \(line.debugDescription) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            DispatchQueue.main.async { done(result) }
        }
    }

    func stop() {
        queue.async { [worker] in worker.stop() }
    }
}

/// State for one connected shell. Lives on the main thread.
final class Session {
    let connection: Connection
    private weak var presenter: Presenter?
    private let learning: Learning

    private(set) var pid: Int32 = 0
    private(set) var tty = ""
    private var path = "/usr/bin:/bin:/usr/sbin:/sbin"
    private var snapshot = (path: "", signature: "")
    private var completer: Completer?

    private var state: EditorState?
    private var context: CompletionContext?
    private var cache: (key: String, candidates: [Candidate])?
    private var inFlight: String?
    private var dismissedKey: String?
    private var shown: [Suggestion] = []
    private var staleHide: DispatchWorkItem?

    init(connection: Connection, presenter: Presenter, learning: Learning) {
        self.connection = connection
        self.presenter = presenter
        self.learning = learning
    }

    func handle(_ message: ShellMessage) {
        switch message {
        case let .hello(pid, tty, fpath):
            self.pid = pid
            self.tty = tty
            completer?.stop()
            completer = Completer(fpath: fpath)
            Log.write("shell \(pid) connected on \(tty)")
        case let .environment(path):
            self.path = path
            cache = nil
        case let .snapshot(path, signature):
            snapshot = (path, signature)
            cache = nil
        case let .update(state):
            update(state)
        case let .select(index):
            presenter?.select(index, owner: self)
        case let .accept(text):
            if let s = shown.first(where: { $0.insertion == text }) {
                learning.record(command: context?.command ?? "", word: s.candidate.word)
            }
            hide()
        case .dismiss:
            dismissedKey = key
            hide()
        case .hide:
            state = nil
            hide()
        }
    }

    func disconnected() {
        presenter?.hide(owner: self)
        completer?.stop()
        if snapshot.path.hasSuffix("/shell-\(pid).zsh") { unlink(snapshot.path) }
        Log.write("shell \(pid) disconnected")
    }

    /// The app hid the panel itself (focus change, click elsewhere).
    func closedByApp() {
        shown = []
        connection.send(.closed)
    }

    /// The user clicked a row.
    func pick(_ index: Int) {
        guard let state else { return }
        connection.send(.pick(seq: state.seq, index: index))
    }

    private var key: String? {
        guard let state, let context else { return nil }
        return state.cwd + "\u{0}" + context.cacheKey
    }

    private func update(_ state: EditorState) {
        self.state = state
        guard let context = CompletionContext.parse(state.buffer),
              !(context.isCommandPosition && context.query.isEmpty) else {
            self.context = nil
            return reply(none: state.seq)
        }
        self.context = context
        guard let key else { return }
        if dismissedKey != nil, dismissedKey != key { dismissedKey = nil }
        if dismissedKey == key { return reply(none: state.seq) }

        if cache?.key == key {
            present()
        } else {
            // Keep the old list briefly to avoid flicker; drop it if the new
            // one is slow, since the shell no longer accepts from it.
            staleHide?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            staleHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            request(key: key, line: context.line, cwd: state.cwd)
        }
    }

    private func request(key: String, line: String, cwd: String) {
        guard let completer else { return }
        guard inFlight == nil else { return }  // the newest key is requested when this one finishes
        inFlight = key
        completer.complete(line: line, cwd: cwd, path: path, snapshot: snapshot) { [weak self] result in
            guard let self else { return }
            self.inFlight = nil
            switch result {
            case let .success(candidates):
                self.cache = (key, candidates)
            case let .failure(error):
                Log.write("completion failed: \(error)")
                Log.debug("failed line: \(line.debugDescription)")
                self.cache = (key, [])
            }
            guard let state = self.state, let context = self.context, let current = self.key else { return }
            if current == key {
                self.present()
            } else {
                self.request(key: current, line: context.line, cwd: state.cwd)
            }
        }
    }

    private func present() {
        staleHide?.cancel()
        guard let state, let context, let cache else { return }
        if context.query.isEmpty, cache.candidates.count > 2000 { return reply(none: state.seq) }
        let ranked = Ranker.rank(cache.candidates, for: context) { [learning] in
            learning.boost(command: context.command, word: $0.word)
        }
        // Nothing useful: no matches, or the word is already complete.
        if ranked.isEmpty || (ranked.count == 1 && ranked[0].candidate.matchText(for: context).text == context.query) {
            return reply(none: state.seq)
        }
        shown = ranked
        connection.send(.items(seq: state.seq, insertions: ranked.map { Insertion(replace: $0.replace, text: $0.insertion) }))
        let top = ranked[0].candidate
        let typed = context.query.count + (top.display.hasPrefix(context.anchor) ? context.anchor.count : 0)
        presenter?.show(ranked, selected: 0, state: state, alignCols: typed, tty: tty, owner: self)
    }

    private func reply(none seq: Int) {
        connection.send(.none(seq: seq))
        hide()
    }

    private func hide() {
        staleHide?.cancel()
        shown = []
        presenter?.hide(owner: self)
    }
}
