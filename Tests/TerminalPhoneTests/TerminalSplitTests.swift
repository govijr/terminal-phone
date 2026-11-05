import XCTest
import TerminalPhoneCore
@testable import TerminalPhone

final class TerminalSplitTests: XCTestCase {
    private let command = "terminal-phone view work"
    private func plan(_ env: [String: String], _ direction: SplitDirection = .right, client: String? = nil) throws -> TerminalSplit.Plan {
        try TerminalSplit.plan(profile: TerminalProfile.detect(env, tmuxClientTerm: client), environment: env, direction: direction,
                               command: command, directory: "/work", tty: "/dev/ttys004", find: { "/bin/\($0)" })
    }

    func testTmuxSplitsBesideTheCallingPane() throws {
        let env = ["TMUX": "/tmp/tmux,1,0", "TMUX_PANE": "%3", "TERM_PROGRAM": "tmux"]
        XCTAssertEqual(try plan(env, .left, client: "xterm-ghostty").steps,
                       [.init(executable: "/bin/tmux", arguments: ["split-window", "-h", "-b", "-l", "45%", "-c", "/work", "-t", "%3", "--", "/bin/sh", "-c", command])])
        XCTAssertEqual(try plan(env, .down).steps.first?.arguments.prefix(2), ["split-window", "-v"])
    }

    func testKittyUsesRemoteControlNextToThisWindow() throws {
        let steps = try plan(["TERM": "xterm-kitty", "KITTY_WINDOW_ID": "7", "KITTY_LISTEN_ON": "unix:/tmp/kitty"]).steps
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps[0].optional)
        XCTAssertEqual(steps[0].arguments, ["@", "--to", "unix:/tmp/kitty", "goto-layout", "--match", "id:7", "splits"])
        XCTAssertEqual(steps[1].arguments, ["@", "--to", "unix:/tmp/kitty", "launch", "--type=window", "--location=vsplit", "--bias=45",
                                            "--cwd=/work", "--next-to", "id:7", "--", "/bin/sh", "-c", command])
        XCTAssertThrowsError(try plan(["TERM": "xterm-kitty"], .left))
    }

    func testWezTermSplitsTheCurrentPane() throws {
        XCTAssertEqual(try plan(["TERM_PROGRAM": "WezTerm", "WEZTERM_PANE": "4"], .up).steps,
                       [.init(executable: "/bin/wezterm", arguments: ["cli", "split-pane", "--pane-id", "4", "--top", "--percent", "45", "--cwd", "/work", "--", "/bin/sh", "-c", command])])
    }

    func testITermAndGhosttyUseAppleEvents() throws {
        let iterm = try plan(["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:9F3C-11"], .down).steps[0]
        XCTAssertEqual(iterm.executable, "/usr/bin/osascript")
        XCTAssertEqual(Array(iterm.arguments.suffix(3)), ["9F3C-11", "/bin/sh -c 'terminal-phone view work'", "down"])
        XCTAssertThrowsError(try plan(["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:9F3C-11"], .left))

        let ghostty = try plan(["TERM_PROGRAM": "ghostty", "TERM_PROGRAM_VERSION": "1.3.1"], .left).steps[0]
        XCTAssertEqual(Array(ghostty.arguments.prefix(2)), ["-l", "JavaScript"])
        XCTAssertEqual(Array(ghostty.arguments.suffix(4)), ["/dev/ttys004", "/work", "GSlf", "/bin/sh -c 'terminal-phone view work'"])
        XCTAssertThrowsError(try plan(["TERM_PROGRAM": "ghostty", "TERM_PROGRAM_VERSION": "1.2.3"]))
    }

    func testTerminalsWithoutSplitsOpenAWindowOrExplain() throws {
        let apple = try plan(["TERM_PROGRAM": "Apple_Terminal"])
        XCTAssertNotNil(apple.note)
        XCTAssertTrue(apple.steps[0].arguments[1].contains("do script"))
        XCTAssertNotNil(try plan(["ALACRITTY_WINDOW_ID": "1"]).note)
        for env in [["TERM_PROGRAM": "WarpTerminal"], ["TERM_PROGRAM": "vscode"], ["TERM": "xterm"]] {
            XCTAssertThrowsError(try plan(env)) { error in XCTAssertTrue(error.localizedDescription.contains(self.command)) }
        }
    }

    func testPaneCommandQuotesAndKeepsFailuresVisible() {
        let command = TerminalSplit.paneCommand(executable: "/Users/me/my apps/terminal-phone", arguments: ["view", "work"],
                                                environment: ["TERMINAL_PHONE_HOME": "/tmp/phone home", "PATH": "/bin"])
        XCTAssertEqual(command, "env TERMINAL_PHONE_HOME='/tmp/phone home' '/Users/me/my apps/terminal-phone' view work || { printf '\\nPress return to close. '; read _; }")
    }
}
