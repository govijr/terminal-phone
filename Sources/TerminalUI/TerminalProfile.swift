import Foundation

/// The terminal emulator the viewer is drawing into, as far as the environment tells us.
public enum TerminalApp: String, CaseIterable, Sendable {
    case ghostty, kitty, iterm, wezterm, warp, vscode, apple, alacritty, unknown

    public var displayName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .kitty: "kitty"
        case .iterm: "iTerm2"
        case .wezterm: "WezTerm"
        case .warp: "Warp"
        case .vscode: "VS Code"
        case .apple: "Terminal"
        case .alacritty: "Alacritty"
        case .unknown: "this terminal"
        }
    }
}

/// How the phone's pixels reach the screen.
public enum GraphicsMode: String, CaseIterable, Sendable {
    /// Kitty graphics protocol: Ghostty, kitty, and anything that answers its query.
    case kitty
    /// iTerm2 inline images: iTerm2, WezTerm, Warp, and VS Code/Cursor with images enabled.
    case iterm
    /// Unicode half blocks with 24-bit or 256 colours. Works in every terminal.
    case blocks
}

public enum ColorDepth: String, Sendable { case truecolor, ansi256 }

/// What the viewer may assume about the terminal before it probes it.
public struct TerminalProfile: Equatable, Sendable {
    public var app: TerminalApp
    /// The emulator runs this tmux session's client, so graphics need passthrough.
    public var tmux: Bool
    /// The first guess. Probes can still upgrade blocks to kitty, or downgrade kitty or iTerm2 to blocks.
    public var graphics: GraphicsMode
    public var colors: ColorDepth
    /// Some fonts (Terminal, VS Code's default) lack glyphs like ⏻ or ①; use a plainer set there.
    public var richGlyphs: Bool
    /// The inline-image result depends on a reply, not on the environment alone.
    public var needsGraphicsProbe: Bool

    public var displayName: String { tmux ? "\(app.displayName) via tmux" : app.displayName }

    public init(app: TerminalApp, tmux: Bool = false, graphics: GraphicsMode, colors: ColorDepth = .truecolor,
                richGlyphs: Bool = true, needsGraphicsProbe: Bool = false) {
        self.app = app; self.tmux = tmux; self.graphics = graphics; self.colors = colors
        self.richGlyphs = richGlyphs; self.needsGraphicsProbe = needsGraphicsProbe
    }

    /// Detects the terminal from environment variables. `tmuxClientTerm` is tmux's
    /// `#{client_termname}`, which names the real emulator when we run inside tmux.
    public static func detect(_ env: [String: String], tmuxClientTerm: String? = nil) -> TerminalProfile {
        let tmux = env["TMUX"] != nil
        let term = env["TERM"] ?? "", program = env["TERM_PROGRAM"] ?? ""
        // Inside tmux, TERM and TERM_PROGRAM describe tmux. The client's TERM and the variables
        // the emulator exported before tmux started still name the real terminal.
        let outerTerm = tmux ? (tmuxClientTerm ?? "") : term
        let outerProgram = tmux && (program == "tmux" || program.isEmpty) ? "" : program
        let app: TerminalApp
        if env["KITTY_WINDOW_ID"] != nil || outerTerm.contains("kitty") { app = .kitty }
        else if outerProgram == "ghostty" || outerTerm.contains("ghostty") || env["GHOSTTY_RESOURCES_DIR"] != nil { app = .ghostty }
        else if outerProgram == "iTerm.app" || env["LC_TERMINAL"] == "iTerm2" || (outerProgram.isEmpty && env["ITERM_SESSION_ID"] != nil) { app = .iterm }
        else if outerProgram == "WezTerm" || env["WEZTERM_PANE"] != nil || outerTerm.contains("wezterm") { app = .wezterm }
        else if outerProgram == "WarpTerminal" { app = .warp }
        else if outerProgram == "vscode" || env["VSCODE_INJECTION"] != nil { app = .vscode }
        else if outerProgram == "Apple_Terminal" { app = .apple }
        else if env["ALACRITTY_WINDOW_ID"] != nil || outerTerm.contains("alacritty") { app = .alacritty }
        else { app = .unknown }

        let colorterm = (env["COLORTERM"] ?? "").lowercased()
        let truecolor = colorterm == "truecolor" || colorterm == "24bit" || ![.apple, .unknown].contains(app)
        let graphics: GraphicsMode, probe: Bool
        switch app {
        case .ghostty, .kitty: graphics = .kitty; probe = true
        case .iterm, .wezterm, .warp: graphics = .iterm; probe = false
        // xterm.js shows images only when the user enabled them; its DA1 reply says so.
        case .vscode: graphics = .iterm; probe = true
        case .unknown: graphics = .blocks; probe = true
        case .apple, .alacritty: graphics = .blocks; probe = false
        }
        return TerminalProfile(app: app, tmux: tmux, graphics: graphics, colors: truecolor ? .truecolor : .ansi256,
                               richGlyphs: ![.apple, .vscode, .unknown].contains(app), needsGraphicsProbe: probe)
    }

    /// Wraps an escape sequence so tmux forwards it to the real terminal (tmux 3.3+ with allow-passthrough).
    public static func tmuxPassthrough(_ escape: String) -> String {
        guard !escape.isEmpty else { return "" }
        return "\u{1b}Ptmux;" + escape.replacingOccurrences(of: "\u{1b}", with: "\u{1b}\u{1b}") + "\u{1b}\\"
    }
}

/// Nearest xterm 256-colour index for an sRGB colour, for terminals without 24-bit colour.
public enum ANSI256 {
    private static let levels = [0, 95, 135, 175, 215, 255]
    public static func index(_ rgb: UInt32) -> Int {
        let r = Int(rgb >> 16 & 255), g = Int(rgb >> 8 & 255), b = Int(rgb & 255)
        func level(_ value: Int) -> Int { levels.indices.min(by: { abs(levels[$0] - value) < abs(levels[$1] - value) })! }
        let (cr, cg, cb) = (level(r), level(g), level(b))
        let cube = 16 + 36 * cr + 6 * cg + cb
        let cubeDistance = distance(r, g, b, levels[cr], levels[cg], levels[cb])
        let gray = max(0, min(23, ((r + g + b) / 3 - 8 + 5) / 10)), value = 8 + gray * 10
        return distance(r, g, b, value, value, value) < cubeDistance ? 232 + gray : cube
    }
    private static func distance(_ r: Int, _ g: Int, _ b: Int, _ r2: Int, _ g2: Int, _ b2: Int) -> Int {
        (r - r2) * (r - r2) + (g - g2) * (g - g2) + (b - b2) * (b - b2)
    }
}
