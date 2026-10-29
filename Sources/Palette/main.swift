import AppKit

let arguments = CommandLine.arguments.dropFirst()

// `palette <command>`; flags (including ones macOS passes) start the app.
if let first = arguments.first, !first.hasPrefix("-") {
    exit(CLI.run(Array(arguments)))
}

if arguments.contains("--help") {
    print("""
    Palette — Fig-style autocomplete for zsh.

      Palette              run the menu-bar app
      Palette <command>    see `Palette help` for the command-line tool
      Palette --headless   serve completions without UI and print panel events (testing)
      Palette --source     print the line to add to ~/.zshrc
      Palette --version    print the version
    """)
    exit(0)
}

if arguments.contains("--version") {
    print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    exit(0)
}

if arguments.contains("--source") {
    print(ShellIntegration.sourceLine)
    exit(0)
}

if let i = arguments.firstIndex(of: "--render"), arguments.indices.contains(i + 1) {
    // Renders the dropdown with sample rows to a PNG, for design checks.
    let dark = arguments.contains("--dark")
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    exit(SuggestionPanel.render(to: URL(fileURLWithPath: arguments[i + 1])) ? 0 : 1)
}

if arguments.contains("--headless") {
    let hub = Hub()
    let presenter = HeadlessPresenter()
    do {
        try hub.start(presenter: presenter)
    } catch {
        FileHandle.standardError.write(Data("palette: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    signal(SIGTERM) { _ in exit(0) }
    print("ready")
    fflush(stdout)
    withExtendedLifetime((hub, presenter)) { dispatchMain() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
