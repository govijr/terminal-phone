import XCTest
import TerminalPhoneCore

final class TerminalProfileTests: XCTestCase {
    func testDetectsEachMajorTerminalAndItsGraphics() {
        let cases: [([String: String], TerminalApp, GraphicsMode)] = [
            (["TERM_PROGRAM": "ghostty", "TERM": "xterm-ghostty"], .ghostty, .kitty),
            (["TERM": "xterm-kitty", "KITTY_WINDOW_ID": "3"], .kitty, .kitty),
            (["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:ABC"], .iterm, .iterm),
            (["TERM_PROGRAM": "WezTerm", "WEZTERM_PANE": "1"], .wezterm, .iterm),
            (["TERM_PROGRAM": "WarpTerminal"], .warp, .iterm),
            (["TERM_PROGRAM": "vscode"], .vscode, .iterm),
            (["TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"], .apple, .blocks),
            (["TERM": "alacritty", "ALACRITTY_WINDOW_ID": "1"], .alacritty, .blocks),
            (["TERM": "xterm-256color"], .unknown, .blocks),
        ]
        for (env, app, graphics) in cases {
            let profile = TerminalProfile.detect(env)
            XCTAssertEqual(profile.app, app, "\(env)")
            XCTAssertEqual(profile.graphics, graphics, "\(env)")
            XCTAssertFalse(profile.tmux)
        }
        // VS Code only shows images when the user enabled them, so it is probed.
        XCTAssertTrue(TerminalProfile.detect(["TERM_PROGRAM": "vscode"]).needsGraphicsProbe)
        XCTAssertFalse(TerminalProfile.detect(["TERM_PROGRAM": "vscode"]).richGlyphs)
    }

    func testColourDepthFollowsCOLORTERMWhereTheTerminalIsUnknownOrApple() {
        XCTAssertEqual(TerminalProfile.detect(["TERM_PROGRAM": "Apple_Terminal"]).colors, .ansi256)
        XCTAssertEqual(TerminalProfile.detect(["TERM_PROGRAM": "Apple_Terminal", "COLORTERM": "truecolor"]).colors, .truecolor)
        XCTAssertEqual(TerminalProfile.detect(["TERM": "xterm"]).colors, .ansi256)
        XCTAssertEqual(TerminalProfile.detect(["TERM_PROGRAM": "ghostty"]).colors, .truecolor)
    }

    func testInsideTmuxTheClientTerminalIsUsed() {
        let env = ["TMUX": "/tmp/tmux-501/default,1,0", "TERM": "tmux-256color", "TERM_PROGRAM": "tmux"]
        let ghostty = TerminalProfile.detect(env, tmuxClientTerm: "xterm-ghostty")
        XCTAssertEqual(ghostty.app, .ghostty); XCTAssertTrue(ghostty.tmux); XCTAssertEqual(ghostty.graphics, .kitty)
        XCTAssertEqual(ghostty.displayName, "Ghostty via tmux")
        // iTerm2's exported variables survive into tmux even though TERM_PROGRAM is tmux's.
        var iterm = env; iterm["LC_TERMINAL"] = "iTerm2"
        XCTAssertEqual(TerminalProfile.detect(iterm, tmuxClientTerm: "xterm-256color").app, .iterm)
        XCTAssertEqual(TerminalProfile.detect(env, tmuxClientTerm: "xterm-256color").graphics, .blocks)
    }

    func testTmuxPassthroughDoublesEscapes() {
        XCTAssertEqual(TerminalProfile.tmuxPassthrough("\u{1b}_Ga=q;\u{1b}\\"), "\u{1b}Ptmux;\u{1b}\u{1b}_Ga=q;\u{1b}\u{1b}\\\u{1b}\\")
        XCTAssertEqual(TerminalProfile.tmuxPassthrough(""), "")
    }

    func testANSI256PicksCubeAndGrayColours() {
        XCTAssertEqual(ANSI256.index(0x000000), 16)
        XCTAssertEqual(ANSI256.index(0xffffff), 231)
        XCTAssertEqual(ANSI256.index(0xff0000), 196)
        XCTAssertEqual(ANSI256.index(0x808080), 244)
    }

    func testPaletteFollowsTheTerminalBackground() {
        XCTAssertEqual(Palette.matching(background: nil), .dark)
        XCTAssertEqual(Palette.matching(background: 0x1a1b26), .dark)
        XCTAssertEqual(Palette.matching(background: 0xfafafa), .light)
    }

    func testDeviceAttributesReplyIsCapturedNotTyped() {
        var filter = PhoneMetricFilter()
        XCTAssertEqual(filter.feed(Array("a\u{1b}[?62;4;22cb".utf8)), Array("ab".utf8))
        XCTAssertEqual(filter.primaryAttributes, [62, 4, 22])
    }

    func testHalfBlocksDrawTwoPixelsPerCellAndOnlyRedrawChanges() {
        // 2 columns × 1 row = 2×2 pixels: red over blue, then transparent over green.
        var rgba: [UInt8] = [255, 0, 0, 255,   0, 0, 0, 0,
                             0, 0, 255, 255,   0, 255, 0, 255]
        let cells = rgba.withUnsafeBytes { HalfBlocks.cells(rgba: $0, bytesPerRow: 8, columns: 2, rows: 1) }
        XCTAssertEqual(cells, [HalfBlocks.Cell(top: 0xff0000, bottom: 0x0000ff), HalfBlocks.Cell(top: nil, bottom: 0x00ff00)])
        var blocks = HalfBlocks(columns: 2, rows: 1)
        let first = blocks.render(cells, column: 5, row: 3, depth: .truecolor)
        XCTAssertEqual(first, "\u{1b}[3;5H\u{1b}[0;38;2;255;0;0;48;2;0;0;255m▀\u{1b}[0;38;2;0;255;0m▄\u{1b}[0m")
        XCTAssertEqual(blocks.render(cells, column: 5, row: 3, depth: .truecolor), "")
        // A menu over the first cell keeps it from being drawn.
        rgba[0] = 0
        let changed = rgba.withUnsafeBytes { HalfBlocks.cells(rgba: $0, bytesPerRow: 8, columns: 2, rows: 1) }
        XCTAssertEqual(blocks.render(changed, column: 5, row: 3, depth: .truecolor, mask: CellRect(column: 5, row: 3, columns: 1, rows: 1)), "")
        XCTAssertTrue(blocks.render(changed, column: 5, row: 3, depth: .ansi256, force: true).contains("38;5;"))
    }

    func testKittyPlaceholdersNumberEachRunAndSkipTheMask() {
        XCTAssertEqual(KittyPlaceholders.diacritics.count, 297)
        let text = KittyPlaceholders.cells(imageID: 2, column: 4, row: 1, columns: 3, rows: 2, mask: CellRect(column: 5, row: 2, columns: 1, rows: 1))
        let p = KittyPlaceholders.placeholder
        let d = { (i: Int) in String(Character(UnicodeScalar(KittyPlaceholders.diacritics[i])!)) }
        XCTAssertEqual(text, "\u{1b}[0m\u{1b}[38;5;2m" +
                       "\u{1b}[1;4H" + p + d(0) + d(0) + p + p +
                       "\u{1b}[2;4H" + p + d(1) + d(0) +
                       "\u{1b}[2;6H" + p + d(1) + d(2) +
                       "\u{1b}[39m")
    }
}
