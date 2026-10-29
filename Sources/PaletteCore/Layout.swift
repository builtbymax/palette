import CoreGraphics

/// A terminal pane's cell grid in screen coordinates (top-left origin, y
/// growing downwards, as used by the Accessibility API).
public struct TerminalGrid: Equatable {
    /// Frame of the terminal surface, including its padding.
    public var surface: CGRect
    public var cols: Int
    public var rows: Int
    /// Cell size in points, when the terminal reports pixel dimensions.
    public var cell: CGSize?
    /// Left and top padding in points. Nil centres the grid on that axis
    /// (Ghostty with `window-padding-balance`, and the safe default).
    public var paddingX: CGFloat?
    public var paddingY: CGFloat?

    public init(surface: CGRect, cols: Int, rows: Int, cell: CGSize? = nil,
                paddingX: CGFloat? = nil, paddingY: CGFloat? = nil) {
        self.surface = surface
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        self.cell = cell
        self.paddingX = paddingX
        self.paddingY = paddingY
    }

    public var cellSize: CGSize {
        if let cell, cell.width > 0, cell.height > 0 { return cell }
        return CGSize(width: (surface.width - 2 * (paddingX ?? 0)) / CGFloat(cols),
                      height: (surface.height - 2 * (paddingY ?? 0)) / CGFloat(rows))
    }

    public var origin: CGPoint {
        let size = cellSize
        let gridWidth = size.width * CGFloat(cols), gridHeight = size.height * CGFloat(rows)
        return CGPoint(x: surface.minX + (paddingX ?? max(0, (surface.width - gridWidth) / 2)),
                       y: surface.minY + (paddingY ?? max(0, (surface.height - gridHeight) / 2)))
    }

    /// Rectangle of the cell at a zero-based row and column.
    public func rect(row: Int, col: Int) -> CGRect {
        let size = cellSize
        let r = min(max(row, 0), rows - 1), c = min(max(col, 0), cols - 1)
        return CGRect(x: origin.x + CGFloat(c) * size.width, y: origin.y + CGFloat(r) * size.height,
                      width: size.width, height: size.height)
    }
}

public enum Placement {
    /// Frame (top-left origin) for a panel anchored to `anchor`, the start of
    /// the word being completed. It goes below the line, shortened to as few
    /// as `minimumHeight` if needed, and above only when even that doesn't
    /// fit. `inset` is the panel's text inset so labels line up with the word.
    public static func frame(anchor: CGRect, panel: CGSize, minimumHeight: CGFloat, screen: CGRect,
                             inset: CGFloat, gap: CGFloat = 5) -> CGRect {
        let margin: CGFloat = 4
        let x = min(max(anchor.minX - inset, screen.minX + margin), screen.maxX - panel.width - margin)
        let below = anchor.maxY + gap
        let room = screen.maxY - margin - below
        if room >= min(panel.height, minimumHeight) {
            return CGRect(x: x, y: below, width: panel.width, height: min(panel.height, room))
        }
        let height = min(panel.height, anchor.minY - gap - screen.minY - margin)
        return CGRect(x: x, y: anchor.minY - gap - height, width: panel.width, height: height)
    }
}
