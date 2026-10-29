import AppKit
import PaletteCore
import SwiftUI

/// The dropdown. A borderless, non-activating panel: it never takes keyboard
/// focus from the terminal. Keys are handled by the shell plugin.
final class SuggestionPanel: Presenter {
    enum Metrics {
        static let rowHeight: CGFloat = 26
        static let maxRows = 8
        /// Fewer rows than this fit below the cursor: open above instead.
        static let minRows = 4
        static let padding: CGFloat = 5
        static let iconWidth: CGFloat = 18
        static let gap: CGFloat = 8
        static let rowInset: CGFloat = 8
        static let footerHeight: CGFloat = 30
        /// Longer descriptions are truncated in the row and shown in full below.
        static let descriptionLimit: CGFloat = 300
        /// Distance from the panel's left edge to the start of a label.
        static var textInset: CGFloat { padding + rowInset + iconWidth + gap }
        static let nameFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        static let descriptionFont = NSFont.systemFont(ofSize: 12)
    }

    private let panel: NSPanel
    private let model = SuggestionModel()
    private weak var owner: Session?
    private var anchor: CGRect = .zero
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var lastSummary = ""

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: SuggestionList(model: model) { [weak self] index in
            self?.owner?.pick(index)
        })
        host.sizingOptions = []
        panel.contentView = host

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeFromApp()
        } as Any)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.closeFromApp() }
    }

    func show(_ suggestions: [Suggestion], selected: Int, state: EditorState, alignCols: Int, tty: String, owner: Session) {
        guard let location = TerminalLocator.locate(tty: tty) else {
            Log.debug("no terminal location for \(tty)")
            return hide(owner: owner)
        }
        let summary = "locate: \(location.summary) cursor=\(state.row),\(state.col)"
        if summary != lastSummary {
            lastSummary = summary
            Log.debug(summary)
        }
        self.owner = owner
        let grid = location.grid
        if state.row >= 0 {
            let caret = grid.rect(row: state.row, col: state.col)
            let wordCol = state.col - alignCols
            anchor = wordCol >= 0 ? grid.rect(row: state.row, col: wordCol) : caret
            if wordCol < 0 { anchor.origin.x = grid.origin.x }
        } else {
            // Cursor row unknown: sit at the bottom-left of the pane.
            anchor = grid.rect(row: grid.rows - 1, col: 0)
        }
        screen = location.screen
        model.items = suggestions
        model.selected = selected
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func select(_ index: Int, owner: Session) {
        guard owner === self.owner, panel.isVisible else { return }
        model.selected = index
        layout()
    }

    func hide(owner: Session) {
        guard owner === self.owner || self.owner == nil else { return }
        panel.orderOut(nil)
        self.owner = nil
    }

    private func closeFromApp() {
        guard panel.isVisible, let owner else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == getpid() { return }
        if NSEvent.mouseLocation.isInside(panel.frame) { return }
        panel.orderOut(nil)
        self.owner = nil
        owner.closedByApp()
    }

    private func layout() {
        guard let screen else { return }
        let size = Self.size(for: model.items, selected: model.selected)
        let visible = TerminalLocator.axRect(screen.visibleFrame)
        let minimum = CGFloat(Metrics.minRows) * Metrics.rowHeight + 2 * Metrics.padding
        let frame = Placement.frame(anchor: anchor, panel: size, minimumHeight: minimum, screen: visible,
                                    inset: Metrics.textInset)
        panel.setFrame(TerminalLocator.cocoaRect(frame), display: true)
    }

    static func size(for items: [Suggestion], selected: Int) -> CGSize {
        var nameWidth: CGFloat = 0, descriptionWidth: CGFloat = 0
        for s in items.prefix(200) {
            nameWidth = max(nameWidth, (s.candidate.display as NSString).size(withAttributes: [.font: Metrics.nameFont]).width)
            descriptionWidth = max(descriptionWidth,
                                   (s.candidate.description as NSString).size(withAttributes: [.font: Metrics.descriptionFont]).width)
        }
        var width = Metrics.textInset + ceil(nameWidth) + Metrics.rowInset + Metrics.padding
        if descriptionWidth > 0 { width += 24 + min(ceil(descriptionWidth), Metrics.descriptionLimit) }
        width = min(max(width, 240), 620)
        let rows = CGFloat(min(items.count, Metrics.maxRows))
        var height = rows * Metrics.rowHeight + 2 * Metrics.padding
        if hasFooter(items, selected) { height += Metrics.footerHeight + 12 }
        return CGSize(width: width, height: height)
    }

    static func hasFooter(_ items: [Suggestion], _ selected: Int) -> Bool {
        guard items.indices.contains(selected) else { return false }
        let text = items[selected].candidate.description as NSString
        return text.size(withAttributes: [.font: Metrics.descriptionFont]).width > Metrics.descriptionLimit
    }
}

extension SuggestionPanel {
    static func render(to url: URL) -> Bool {
        let context = CompletionContext.parse("git ch")!
        let candidates = [
            ("checkout", "switch branches or restore working tree files"),
            ("cherry-pick", "apply changes introduced by some existing commits"),
            ("cherry", "find commits not merged upstream"),
            ("check-ignore", "debug gitignore/exclude files"),
            ("switch", "switch branches"),
        ].map { Candidate(tag: "main-porcelain-commands", display: $0.0, word: $0.0, description: $0.1) }
            + [Candidate(tag: "heads-local", display: "chore/release", word: "chore/release", description: "")]
        let items = Ranker.rank(candidates, for: context)
        let model = SuggestionModel()
        model.items = items
        model.selected = 0
        let size = size(for: items, selected: 0)
        let host = NSHostingView(rootView: SuggestionList(model: model) { _ in })
        host.frame = CGRect(origin: .zero, size: size)
        let backdrop = NSView(frame: host.frame.insetBy(dx: -24, dy: -24).offsetBy(dx: 24, dy: 24))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.frame.origin = CGPoint(x: 24, y: 24)
        backdrop.addSubview(host)
        backdrop.layoutSubtreeIfNeeded()
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return false }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

private extension CGPoint {
    func isInside(_ rect: CGRect) -> Bool { rect.contains(self) }
}

final class SuggestionModel: ObservableObject {
    @Published var items: [Suggestion] = []
    @Published var selected = 0
}

struct SuggestionList: View {
    @ObservedObject var model: SuggestionModel
    var pick: (Int) -> Void
    typealias M = SuggestionPanel.Metrics

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                            Row(item: item, selected: index == model.selected)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { pick(index) }
                        }
                    }
                    .padding(M.padding)
                }
                .onChange(of: model.selected) { _, value in proxy.scrollTo(value) }
                .onChange(of: model.items) { _, _ in proxy.scrollTo(model.selected) }
            }
            if SuggestionPanel.hasFooter(model.items, model.selected) {
                Divider().opacity(0.5)
                Text(model.items[model.selected].candidate.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: M.footerHeight + 11, alignment: .leading)
                    .padding(.horizontal, M.padding + M.rowInset)
            }
        }
        .background(Blur())
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    struct Row: View {
        let item: Suggestion
        let selected: Bool

        var body: some View {
            let style = Style(item.candidate)
            HStack(spacing: M.gap) {
                Image(systemName: style.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? .white : style.tint)
                    .frame(width: M.iconWidth, height: M.iconWidth)
                    .background(style.tint.opacity(selected ? 0.9 : 0.16), in: RoundedRectangle(cornerRadius: 5))
                Text(highlighted)
                    .font(Font(M.nameFont))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 16)
                if !item.candidate.description.isEmpty {
                    Text(item.candidate.description)
                        .font(Font(M.descriptionFont))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, M.rowInset)
            .frame(height: M.rowHeight)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }

        var highlighted: AttributedString {
            var result = AttributedString()
            let marks = Set(item.highlights)
            for (i, ch) in item.candidate.display.enumerated() {
                var part = AttributedString(String(ch))
                if marks.contains(i) {
                    part.font = Font(NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold))
                    if !selected { part.foregroundColor = .accentColor }
                }
                result += part
            }
            return result
        }
    }

    struct Style {
        let symbol: String
        let tint: Color

        init(_ c: Candidate) {
            let tag = c.tag
            func has(_ s: String) -> Bool { tag.contains(s) }
            switch true {
            case c.isDirectory: (symbol, tint) = ("folder.fill", .blue)
            case has("file"): (symbol, tint) = ("doc.text", .gray)
            case has("option") || c.word.hasPrefix("-"): (symbol, tint) = ("flag.fill", .orange)
            case has("branch") || has("head") || has("ref") || has("commit"): (symbol, tint) = ("arrow.triangle.branch", .purple)
            case has("tag"): (symbol, tint) = ("tag.fill", .purple)
            case has("remote"): (symbol, tint) = ("network", .teal)
            case has("alias"): (symbol, tint) = ("link", .pink)
            case has("function"): (symbol, tint) = ("function", .indigo)
            case has("process") || has("job"): (symbol, tint) = ("cpu", .red)
            case has("host"): (symbol, tint) = ("server.rack", .teal)
            case has("user"): (symbol, tint) = ("person.fill", .teal)
            case has("parameter") || has("variable"): (symbol, tint) = ("dollarsign", .mint)
            case has("command") || has("builtin") || has("porcelain"): (symbol, tint) = ("terminal.fill", .green)
            default: (symbol, tint) = ("chevron.right", .gray)
            }
        }
    }
}

/// Behind-window blur that stays active although the app never activates.
private struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
