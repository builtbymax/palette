import AppKit
import ApplicationServices
import Darwin
import PaletteCore

/// Finds the focused terminal pane on screen and its cell grid.
///
/// Neither Ghostty nor Rex report the caret's screen position, so Palette
/// computes it: the focused pane's Accessibility frame, the grid size and
/// pixel dimensions from the shell's tty, and the terminal's padding rules.
enum TerminalLocator {
    struct Location {
        var grid: TerminalGrid
        var screen: NSScreen
        var appPID: pid_t
        var summary: String
    }

    static func locate(tty: String) -> Location? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return nil }
        let size = windowSize(tty: tty)
        guard let cols = size.map({ Int($0.ws_col) }), let rows = size.map({ Int($0.ws_row) }), cols > 0, rows > 0 else {
            return nil
        }

        var source = "ax"
        var role = ""
        var surface: CGRect?
        var windowFrame: CGRect?
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
            if let focused: AXUIElement = attribute(element, kAXFocusedUIElementAttribute) {
                role = attribute(focused, kAXRoleAttribute) ?? ""
                if role != kAXWindowRole, let frame = frame(of: focused), frame.width > 40, frame.height > 20 {
                    surface = frame
                }
            }
            if let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute) {
                windowFrame = frame(of: window)
                if surface == nil {
                    source = "ax-window"
                    surface = windowFrame.map(contentArea)
                }
            }
        }
        if surface == nil {
            source = "window-list"
            surface = frontWindow(pid: app.processIdentifier).map(contentArea)
        }
        guard let surface else { return nil }
        guard let screen = NSScreen.screens.first(where: { axRect($0.frame).intersects(surface) }) ?? NSScreen.main else {
            return nil
        }

        let scale = screen.backingScaleFactor
        var cell: CGSize?
        if let size, size.ws_xpixel > 0, size.ws_ypixel > 0 {
            for factor in [scale, 1] {
                let candidate = CGSize(width: CGFloat(size.ws_xpixel) / CGFloat(cols) / factor,
                                       height: CGFloat(size.ws_ypixel) / CGFloat(rows) / factor)
                if candidate.width * CGFloat(cols) <= surface.width + 1,
                   candidate.height * CGFloat(rows) <= surface.height + 1 {
                    cell = candidate
                    break
                }
            }
        }

        let padding = TerminalPadding.padding(for: app)
        let grid = TerminalGrid(surface: surface, cols: cols, rows: rows, cell: cell,
                                paddingX: padding.x, paddingY: padding.y)
        let summary = "\(app.bundleIdentifier ?? "?") source=\(source) role=\(role) window=\(windowFrame.map { "\($0)" } ?? "?") surface=\(surface) "
            + "grid=\(cols)x\(rows) px=\(size?.ws_xpixel ?? 0)x\(size?.ws_ypixel ?? 0) scale=\(scale) "
            + "cell=\(grid.cellSize) padding=\(padding.x.map { "\($0)" } ?? "centred"),\(padding.y.map { "\($0)" } ?? "centred") "
            + "origin=\(grid.origin)"
        return Location(grid: grid, screen: screen, appPID: app.processIdentifier, summary: summary)
    }

    /// Converts a Cocoa rect (bottom-left origin) to Accessibility coordinates.
    static func axRect(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoaRect(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func windowSize(tty: String) -> winsize? {
        guard tty.hasPrefix("/dev/") else { return nil }
        let fd = open(tty, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var size = winsize()
        let TIOCGWINSZ: UInt = 0x4008_7468
        guard ioctl(fd, TIOCGWINSZ, &size) == 0 else { return nil }
        return size
    }

    /// Without a pane element, assume a standard title bar.
    private static func contentArea(_ window: CGRect) -> CGRect {
        let titleBar: CGFloat = 28
        return CGRect(x: window.minX, y: window.minY + titleBar, width: window.width, height: window.height - titleBar)
    }

    private static func frontWindow(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (info[kCGWindowLayer as String] as? Int) == 0 {
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: bounds) {
                return rect
            }
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}

/// Grid padding rules per terminal.
enum TerminalPadding {
    private static var ghostty: [String: CGSize?] = [:]
    private static var loading: Set<String> = []

    /// Explicit left/top padding; nil centres the grid on that axis.
    static func padding(for app: NSRunningApplication) -> (x: CGFloat?, y: CGFloat?) {
        switch app.bundleIdentifier {
        case "com.mitchellh.ghostty":
            let size = ghosttyPadding(app)
            return (size?.width, size?.height)
        case "com.superlogical.rex":
            // Rex keeps the grid at the top and leaves the remainder below.
            return (nil, 0)
        default:
            return (nil, nil)
        }
    }

    private static func ghosttyPadding(_ app: NSRunningApplication) -> CGSize? {
        guard let bundle = app.bundleURL else { return nil }
        let binary = bundle.appendingPathComponent("Contents/MacOS/ghostty").path
        if let known = ghostty[binary] { return known }
        guard !loading.contains(binary) else { return nil }
        loading.insert(binary)
        DispatchQueue.global().async {
            let padding = readGhosttyPadding(binary: binary)
            DispatchQueue.main.async {
                ghostty[binary] = .some(padding)
                loading.remove(binary)
                Log.write("ghostty padding: \(padding.map { "\($0)" } ?? "balanced")")
            }
        }
        return nil
    }

    /// Ghostty puts `window-padding-x/y` on the left/top and leaves the
    /// remainder on the right/bottom, unless `window-padding-balance` centres
    /// the grid.
    private static func readGhosttyPadding(binary: String) -> CGSize? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["+show-config"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return CGSize(width: 2, height: 2) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        if values["window-padding-balance"] == "true" { return nil }
        func first(_ key: String) -> CGFloat {
            CGFloat(Double(values[key]?.split(separator: ",").first.map(String.init) ?? "") ?? 2)
        }
        return CGSize(width: first("window-padding-x"), height: first("window-padding-y"))
    }
}
