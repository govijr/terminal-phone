import Foundation

/// A run of text with one style. Widths count characters, so keep to single-width glyphs.
public struct Span {
    public var text: String
    public var style: String = ""
    public init(_ text: String, _ style: String = "") { self.text = text; self.style = style }
}

extension Array where Element == Span {
    public var width: Int { reduce(0) { $0 + $1.text.count } }
    public func truncated(_ limit: Int) -> [Span] {
        var result: [Span] = [], remaining = Swift.max(0, limit)
        for span in self where remaining > 0 {
            if span.text.count <= remaining { result.append(span); remaining -= span.text.count }
            else { result.append(Span(String(span.text.prefix(Swift.max(0, remaining - 1))) + "…", span.style)); remaining = 0 }
        }
        return result
    }
    public var rendered: String { map { $0.style.isEmpty ? $0.text : $0.style + $0.text + Theme.reset }.joined() }
}

/// Colours for one terminal background. Tokyo Night on dark terminals, Tokyo Night Day on light ones.
public struct Palette: Equatable, Sendable {
    public let text, muted, faint, border, accent, green, yellow, red, magenta, cyan: UInt32
    /// Filled areas: menus, pressed keys, the badge's text.
    public let surface, selected, keyBackground, onAccent: UInt32
    public static let dark = Palette(text: 0xc0caf5, muted: 0x737aa2, faint: 0x545c7e, border: 0x3b4261, accent: 0x7aa2f7,
                                     green: 0x9ece6a, yellow: 0xe0af68, red: 0xf7768e, magenta: 0xbb9af7, cyan: 0x7dcfff,
                                     surface: 0x1f2335, selected: 0x2f3549, keyBackground: 0x24283b, onAccent: 0x1a1b26)
    public static let light = Palette(text: 0x3760bf, muted: 0x6172b0, faint: 0x8990b3, border: 0xa8aecb, accent: 0x2e7de9,
                                      green: 0x587539, yellow: 0x8c6c3e, red: 0xf52a65, magenta: 0x9854f1, cyan: 0x007197,
                                      surface: 0xe9e9ed, selected: 0xd0d5e3, keyBackground: 0xd8dce8, onAccent: 0xffffff)
    /// Picks the palette that reads best on a terminal background of 0xRRGGBB.
    public static func matching(background: UInt32?) -> Palette {
        guard let background else { return .dark }
        let r = Double(background >> 16 & 255), g = Double(background >> 8 & 255), b = Double(background & 255)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 > 0.55 ? .light : .dark
    }
}

/// Toolbar and header symbols. The plain set avoids glyphs that common fonts draw wide or not at all.
public struct Glyphs: Equatable, Sendable {
    public let home, lock, control, controlOff, screenshot, record, stop, dark, light, zoomOut, zoomFit, zoomActual, zoomIn, menu, live, idle, check, cross: String
    public static let rich = Glyphs(home: "⌂", lock: "⏻", control: "●", controlOff: "▶", screenshot: "◎", record: "●", stop: "■", dark: "◐", light: "◑",
                                    zoomOut: "⊖", zoomFit: "⊡", zoomActual: "①", zoomIn: "⊕", menu: "⌄", live: "●", idle: "○", check: "✓", cross: "✕")
    public static let plain = Glyphs(home: "⌂", lock: "◉", control: "●", controlOff: "▶", screenshot: "◎", record: "●", stop: "■", dark: "◐", light: "◑",
                                     zoomOut: "−", zoomFit: "□", zoomActual: "1:1", zoomIn: "+", menu: "▾", live: "●", idle: "○", check: "✓", cross: "×")
}

/// The chrome's colours and symbols. Respects NO_COLOR (https://no-color.org).
/// The viewer sets `palette`, `depth` and `glyphs` once it knows the terminal.
public enum Theme {
    public static let color = ProcessInfo.processInfo.environment["NO_COLOR"].map(\.isEmpty) ?? true
    nonisolated(unsafe) public static var palette = Palette.dark
    nonisolated(unsafe) public static var depth = ColorDepth.truecolor
    nonisolated(unsafe) public static var glyphs = Glyphs.rich
    public static let reset = "\u{1b}[0m"
    public static func fg(_ hex: UInt32) -> String {
        guard color else { return "" }
        return depth == .truecolor ? "\u{1b}[38;2;\(hex >> 16 & 255);\(hex >> 8 & 255);\(hex & 255)m" : "\u{1b}[38;5;\(ANSI256.index(hex))m"
    }
    public static func bg(_ hex: UInt32) -> String {
        guard color else { return "" }
        return depth == .truecolor ? "\u{1b}[48;2;\(hex >> 16 & 255);\(hex >> 8 & 255);\(hex & 255)m" : "\u{1b}[48;5;\(ANSI256.index(hex))m"
    }
    public static let bold = "\u{1b}[1m"

    public static var text: String { fg(palette.text) }
    public static var muted: String { fg(palette.muted) }
    public static var faint: String { fg(palette.faint) }
    public static var border: String { fg(palette.border) }
    public static var accent: String { fg(palette.accent) }
    public static var green: String { fg(palette.green) }
    public static var yellow: String { fg(palette.yellow) }
    public static var red: String { fg(palette.red) }
    public static var magenta: String { fg(palette.magenta) }
    public static var cyan: String { fg(palette.cyan) }
    public static var badge: String { bold + fg(palette.onAccent) + bg(palette.accent) }
    public static var key: String { bold + fg(palette.cyan) + bg(palette.keyBackground) }
    public static var surface: String { bg(palette.surface) }
    public static var selected: String { bg(palette.selected) }
    public static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
}

public enum Box {
    /// A rounded box with an optional title in its top edge. The interior is not cleared.
    public static func frame(column: Int, row: Int, width: Int, height: Int, title: [Span] = [], color: String = Theme.border) -> String {
        guard width >= 2, height >= 2 else { return "" }
        var output = "\u{1b}[\(row);\(column)H"
        let label = title.isEmpty ? [] : [Span("─ ", color)] + title.truncated(width - 6) + [Span(" ", color)]
        output += [Span("╭", color)].rendered + label.rendered + [Span(String(repeating: "─", count: max(0, width - 2 - label.width)) + "╮", color)].rendered
        for offset in 1..<(height - 1) {
            output += "\u{1b}[\(row + offset);\(column)H" + [Span("│", color)].rendered + "\u{1b}[\(row + offset);\(column + width - 1)H" + [Span("│", color)].rendered
        }
        output += "\u{1b}[\(row + height - 1);\(column)H" + [Span("╰" + String(repeating: "─", count: width - 2) + "╯", color)].rendered
        return output
    }
    /// Writes `spans` at a position, padding with spaces to `width` so stale text is erased.
    public static func line(column: Int, row: Int, width: Int, _ spans: [Span]) -> String {
        let fitted = spans.truncated(width)
        return "\u{1b}[\(row);\(column)H" + fitted.rendered + String(repeating: " ", count: max(0, width - fitted.width))
    }
}
