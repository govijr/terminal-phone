import XCTest
import Foundation
@testable import TerminalPhoneCore

final class AgentClientConfigTests: XCTestCase {
    private let command = "/Users/me/.local/bin/terminal-phone"

    func testCursorKeepsOtherServersAndRemovesOnlyItsOwn() throws {
        let existing = Data(#"{"mcpServers":{"other":{"command":"/bin/other"}},"theme":"dark"}"#.utf8)
        let added = try AgentClientConfig.cursor(existing: existing, command: command)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: added) as? [String: Any])
        let servers = try XCTUnwrap(parsed["mcpServers"] as? [String: Any])
        XCTAssertEqual(parsed["theme"] as? String, "dark")
        XCTAssertNotNil(servers["other"])
        let ours = try XCTUnwrap(servers["terminal-phone"] as? [String: Any])
        XCTAssertEqual(ours["command"] as? String, command)
        XCTAssertEqual(ours["args"] as? [String], ["mcp"])
        XCTAssertTrue(String(decoding: added, as: UTF8.self).contains(command), "slashes stay readable")

        let removed = try AgentClientConfig.cursor(existing: added, command: nil)
        let after = try XCTUnwrap((JSONSerialization.jsonObject(with: removed) as? [String: Any])?["mcpServers"] as? [String: Any])
        XCTAssertNil(after["terminal-phone"]); XCTAssertNotNil(after["other"])
    }

    func testCursorStartsFromEmptyAndRefusesInvalidJSON() throws {
        XCTAssertNoThrow(try AgentClientConfig.cursor(existing: nil, command: command))
        XCTAssertNoThrow(try AgentClientConfig.cursor(existing: Data("  \n".utf8), command: command))
        XCTAssertThrowsError(try AgentClientConfig.cursor(existing: Data("{ // comment".utf8), command: command))
        XCTAssertThrowsError(try AgentClientConfig.cursor(existing: Data(#"{"mcpServers":[]}"#.utf8), command: command))
    }

    func testCodexReplacesOnlyItsTableAndIsIdempotent() {
        let existing = """
        model = "gpt-5"

        [mcp_servers.terminal-phone]
        command = "/old/terminal-phone"
        args = ["mcp"]

        [mcp_servers.terminal-phone.env]
        TERMINAL_PHONE_HOME = "/tmp/x"

        [mcp_servers.other]
        command = "other"

        """
        let updated = AgentClientConfig.codex(existing: existing, command: command)
        XCTAssertFalse(updated.contains("/old/terminal-phone"))
        XCTAssertFalse(updated.contains("TERMINAL_PHONE_HOME"))
        XCTAssertTrue(updated.contains("model = \"gpt-5\""))
        XCTAssertTrue(updated.contains("[mcp_servers.other]\ncommand = \"other\""))
        XCTAssertTrue(updated.hasSuffix("[mcp_servers.terminal-phone]\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n"))
        XCTAssertEqual(AgentClientConfig.codex(existing: updated, command: command), updated)

        let removed = AgentClientConfig.codex(existing: updated, command: nil)
        XCTAssertFalse(removed.contains("terminal-phone"))
        XCTAssertTrue(removed.contains("[mcp_servers.other]"))
        XCTAssertEqual(AgentClientConfig.codex(existing: "", command: command), "[mcp_servers.terminal-phone]\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n")
    }

    func testCodexEscapesThePath() {
        let toml = AgentClientConfig.codex(existing: "", command: "/Users/a \"b\"\\c/terminal-phone")
        XCTAssertTrue(toml.contains(#"command = "/Users/a \"b\"\\c/terminal-phone""#))
    }

    func testClaudeArgumentsAndSnippetQuoting() {
        XCTAssertEqual(AgentClientConfig.claudeAddArguments(command: command),
                       ["mcp", "add", "--scope", "user", "terminal-phone", "--", command, "mcp"])
        XCTAssertEqual(AgentClientConfig.snippet(for: .claude, command: "/Users/my name/bin/terminal-phone"),
                       "claude mcp add --scope user terminal-phone -- '/Users/my name/bin/terminal-phone' mcp")
    }

    func testStableCommandPrefersTheInstalledLauncher() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-agent-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("unrelated"), installed = root.appendingPathComponent("installed")
        for directory in [unrelated, installed] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("#!/bin/sh\necho someone else\n".utf8).write(to: unrelated.appendingPathComponent("terminal-phone"))
        try Data("#!/bin/sh\n\(AgentClientConfig.launcherMarker)\nexec /x \"$@\"\n".utf8).write(to: installed.appendingPathComponent("terminal-phone"))
        for directory in [unrelated, installed] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("terminal-phone").path)
        }
        let executable = URL(fileURLWithPath: "/opt/runtime/0.3.0-abc/terminal-phone")
        XCTAssertEqual(AgentClientConfig.stableCommand(executable: executable, path: "\(unrelated.path):\(installed.path)"),
                       installed.appendingPathComponent("terminal-phone").path)
        XCTAssertEqual(AgentClientConfig.stableCommand(executable: executable, path: unrelated.path), executable.path)
    }

    func testWriteBacksUpFollowsSymlinksAndSkipsNoOps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-agent-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("dotfiles/config.toml"), link = root.appendingPathComponent("home/.codex/config.toml")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertTrue(try AgentClientConfig.write(Data("new\n".utf8), to: link))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "the symlink survives")
        XCTAssertEqual(try String(contentsOf: real), "new\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        let backups = try FileManager.default.contentsOfDirectory(atPath: real.deletingLastPathComponent().path).filter { $0.contains("terminal-phone-backup") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertFalse(try AgentClientConfig.write(Data("new\n".utf8), to: link))

        let fresh = root.appendingPathComponent("new/.cursor/mcp.json")
        XCTAssertTrue(try AgentClientConfig.write(Data("{}\n".utf8), to: fresh))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
