import AppKit
import SwiftUI

/// Pieces of the menu-bar item: the blackletter P and the dropdown header.
enum StatusMenu {
    /// The brand mark as a template image, so the system tints it for the menu bar.
    static let templateMark: NSImage? = {
        let image = NSImage(contentsOf: Paths.asset("Mark", "svg"))
            ?? NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: nil)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        image?.accessibilityDescription = "Palette"
        return image
    }()

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    static func header(version: String, shells: Int, ready: Bool) -> NSMenuItem {
        let view = NSHostingView(rootView: Header(version: version, shells: shells, ready: ready))
        view.frame.size = view.fittingSize
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private struct Header: View {
        let version: String
        let shells: Int
        let ready: Bool

        private var status: String {
            guard ready else { return "Setup needed" }
            switch shells {
            case 0: return "Ready, no shells yet"
            case 1: return "1 shell connected"
            default: return "\(shells) shells connected"
            }
        }

        var body: some View {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Palette").font(.system(size: 13, weight: .semibold))
                        Text(version).font(.system(size: 11).monospaced()).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(ready ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(width: 260, alignment: .leading)
        }
    }
}
