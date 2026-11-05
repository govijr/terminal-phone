import Foundation

/// Draws an image as text: each cell is "▀" with the upper pixel as foreground and the lower
/// one as background, so a cell shows two pixels. Transparent pixels keep the terminal's own
/// background, so the phone's rounded corners blend in. Works in every terminal, inside tmux too.
public struct HalfBlocks {
    /// One cell's two pixels as 0xRRGGBB, or nil where transparent.
    public struct Cell: Equatable, Sendable {
        public let top: UInt32?, bottom: UInt32?
        public init(top: UInt32?, bottom: UInt32?) { self.top = top; self.bottom = bottom }
    }
    public let columns: Int, rows: Int
    private var previous: [Cell?]

    public init(columns: Int, rows: Int) {
        self.columns = max(0, columns); self.rows = max(0, rows)
        previous = Array(repeating: nil, count: self.columns * self.rows)
    }

    /// Cells from premultiplied RGBA bytes laid out `columns` wide and `rows * 2` tall.
    public static func cells(rgba: UnsafeRawBufferPointer, bytesPerRow: Int, columns: Int, rows: Int) -> [Cell] {
        func pixel(_ x: Int, _ y: Int) -> UInt32? {
            let i = y * bytesPerRow + x * 4
            guard i + 3 < rgba.count else { return nil }
            let a = UInt32(rgba[i + 3])
            guard a >= 96 else { return nil }
            // Undo premultiplication so edge pixels keep their colour.
            func channel(_ v: UInt8) -> UInt32 { min(255, UInt32(v) * 255 / max(1, a)) }
            return channel(rgba[i]) << 16 | channel(rgba[i + 1]) << 8 | channel(rgba[i + 2])
        }
        var result: [Cell] = []
        result.reserveCapacity(columns * rows)
        for r in 0..<rows { for c in 0..<columns { result.append(Cell(top: pixel(c, r * 2), bottom: pixel(c, r * 2 + 1))) } }
        return result
    }

    /// Escapes that bring the screen from the last drawn frame to `cells`, placed at (column, row).
    /// Unchanged cells and cells inside `mask` are skipped. `force` redraws everything.
    public mutating func render(_ cells: [Cell], column: Int, row: Int, depth: ColorDepth, mask: CellRect? = nil, force: Bool = false) -> String {
        guard cells.count == columns * rows else { return "" }
        func fg(_ c: UInt32) -> String { depth == .truecolor ? "38;2;\(c >> 16 & 255);\(c >> 8 & 255);\(c & 255)" : "38;5;\(ANSI256.index(c))" }
        func bg(_ c: UInt32) -> String { depth == .truecolor ? "48;2;\(c >> 16 & 255);\(c >> 8 & 255);\(c & 255)" : "48;5;\(ANSI256.index(c))" }
        var output = "", style = ""
        for r in 0..<rows {
            var cursorAt: Int?
            for c in 0..<columns {
                let index = r * columns + c, cell = cells[index]
                if mask?.contains(column: column + c, row: row + r) == true { continue }
                if !force, previous[index] == cell { continue }
                previous[index] = cell
                if cursorAt != c { output += "\u{1b}[\(row + r);\(column + c)H"; cursorAt = c }
                let glyph: String, wanted: String
                switch (cell.top, cell.bottom) {
                case let (top?, bottom?) where top == bottom: glyph = " "; wanted = "0;" + bg(top)
                case let (top?, bottom?): glyph = "▀"; wanted = "0;" + fg(top) + ";" + bg(bottom)
                case let (top?, nil): glyph = "▀"; wanted = "0;" + fg(top)
                case let (nil, bottom?): glyph = "▄"; wanted = "0;" + fg(bottom)
                case (nil, nil): glyph = " "; wanted = "0"
                }
                if wanted != style { output += "\u{1b}[\(wanted)m"; style = wanted }
                output += glyph; cursorAt = c + 1
            }
        }
        return output.isEmpty ? "" : output + "\u{1b}[0m"
    }
    /// Forgets what is on screen, for example after the screen was cleared.
    public mutating func invalidate() { previous = Array(repeating: nil, count: columns * rows) }
}
