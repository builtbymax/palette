import AppKit
import ApplicationServices
import PaletteCore
import ServiceManagement

/// Owns the socket server and the sessions; shared by the GUI and headless modes.
final class Hub {
    let learning = Learning(url: Paths.support.appendingPathComponent("learning.json"))
    private let server = Server(path: Paths.socket)
    private(set) var sessions: [ObjectIdentifier: Session] = [:]
    var onChange: (() -> Void)?

    static let learningKey = "LearnFromPicks"

    func start(presenter: Presenter) throws {
        if Server.isRunning(at: server.path) {
            throw NSError(domain: "Palette", code: 1, userInfo: [NSLocalizedDescriptionKey: "Palette is already running"])
        }
        UserDefaults.standard.register(defaults: [Self.learningKey: true])
        learning.isEnabled = UserDefaults.standard.bool(forKey: Self.learningKey)
        RuntimeData.clean()
        server.onConnect = { [weak self, weak presenter] connection in
            guard let self, let presenter else { return }
            let session = Session(connection: connection, presenter: presenter, learning: self.learning)
            let id = ObjectIdentifier(session)
            self.sessions[id] = session
            connection.onMessage = { [weak session] in session?.handle($0) }
            connection.onClose = { [weak self] in
                self?.sessions.removeValue(forKey: id)?.disconnected()
                self?.onChange?()
            }
            connection.start()
            self.onChange?()
        }
        try server.start()
        Log.write("listening on \(server.path)")
    }

    func stop() { server.stop() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hub = Hub()
    private var panel: SuggestionPanel!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SuggestionPanel()
        do {
            try hub.start(presenter: panel)
        } catch {
            Log.write("start failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusMenu.templateMark
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        if !ShellIntegration.isInstalled { ShellIntegration.offerInstall() }
        Updater.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()
        let installed = ShellIntegration.isInstalled
        menu.addItem(StatusMenu.header(version: Bundle.main.shortVersion, shells: hub.sessions.count,
                                       ready: trusted && installed))
        menu.addItem(.separator())

        if !trusted || !installed {
            menu.addItem(.sectionHeader(title: "Setup"))
            if !trusted {
                menu.addItem(action("Grant Accessibility Access…", symbol: "lock.shield") {
                    ShellIntegration.openAccessibilitySettings()
                })
            }
            if !installed {
                menu.addItem(action("Install Shell Integration", symbol: "terminal") { ShellIntegration.install() })
            }
            menu.addItem(.separator())
        }

        let login = action("Open at Login", symbol: "power") {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled { try service.unregister() } else { try service.register() }
            } catch {
                Log.write("login item: \(error.localizedDescription)")
            }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let learn = action("Learn From Picks", symbol: "sparkles") { [hub] in
            hub.learning.isEnabled.toggle()
            UserDefaults.standard.set(hub.learning.isEnabled, forKey: Hub.learningKey)
        }
        learn.state = hub.learning.isEnabled ? .on : .off
        menu.addItem(learn)

        let more = NSMenu()
        more.addItem(action("Copy Source Line", symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ShellIntegration.sourceLine, forType: .string)
        })
        more.addItem(action("Open Log", symbol: "doc.text.magnifyingglass") { NSWorkspace.shared.open(Paths.log) })
        let debug = action("Debug Logging", symbol: "ladybug") { Log.verbose.toggle() }
        debug.state = Log.verbose ? .on : .off
        more.addItem(debug)
        more.addItem(.separator())
        more.addItem(action("Forget Learned Suggestions (\(hub.learning.count))", symbol: "arrow.counterclockwise") {
            [hub] in hub.learning.clear()
        })
        let troubleshooting = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        troubleshooting.image = StatusMenu.symbol("wrench.and.screwdriver")
        troubleshooting.submenu = more
        menu.addItem(troubleshooting)

        menu.addItem(.separator())
        let updater = Updater.shared
        if updater.isAvailable {
            let title = updater.pendingVersion.map { "Install Update (\($0))…" } ?? "Check for Updates…"
            menu.addItem(action(title) { updater.checkForUpdates() })
            let automatic = action("Check Automatically") { updater.automaticallyChecks.toggle() }
            automatic.state = updater.automaticallyChecks ? .on : .off
            menu.addItem(automatic)
            menu.addItem(.separator())
        }
        menu.addItem(action("Quit Palette") { NSApp.terminate(nil) }.with(key: "q"))
    }

    private func action(_ title: String, symbol: String? = nil, _ handler: @escaping () -> Void) -> ClosureMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.image = symbol.flatMap(StatusMenu.symbol)
        return item
    }
}

/// Prints presenter events as lines, for end-to-end tests without a GUI.
final class HeadlessPresenter: Presenter {
    func show(_ suggestions: [Suggestion], selected: Int, state: EditorState, alignCols: Int, tty: String, owner: Session) {
        let words = suggestions.prefix(10).map(\.candidate.display).joined(separator: ",")
        emit("show seq=\(state.seq) row=\(state.row) col=\(state.col) align=\(alignCols) items=\(words)")
    }

    func select(_ index: Int, owner: Session) { emit("select \(index)") }
    func hide(owner: Session) { emit("hide") }

    private func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

enum ShellIntegration {
    static let begin = "# >>> palette >>>"
    static let end = "# <<< palette <<<"
    static var zshrc: URL {
        let dir = ProcessInfo.processInfo.environment["ZDOTDIR"].map { URL(fileURLWithPath: $0) } ?? Paths.home
        return dir.appendingPathComponent(".zshrc")
    }

    static var sourceLine: String {
        "source \"\(Paths.script("palette"))\""
    }

    static var isInstalled: Bool {
        (try? String(contentsOf: zshrc, encoding: .utf8))?.contains(begin) ?? false
    }

    static func install() {
        let block = "\n\(begin)\n# Keep this last so Palette's key bindings win.\n\(sourceLine)\n\(end)\n"
        do {
            let url = zshrc.resolvingSymlinksInPath()
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(block.utf8))
                try handle.close()
            } else {
                try Data(block.utf8).write(to: url)
            }
            Log.write("installed shell integration in \(url.path)")
            alert("Shell integration installed",
                  "Open a new terminal tab or window, then start typing a command such as `git `.")
        } catch {
            alert("Could not update \(zshrc.path)", error.localizedDescription)
        }
    }

    static func offerInstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set up Palette for zsh?"
        alert.informativeText = "Palette adds one line to \(zshrc.path):\n\n\(sourceLine)"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { install() }
    }

    static func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func run() { handler() }

    func with(key: String) -> Self {
        keyEquivalent = key
        return self
    }
}

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}
