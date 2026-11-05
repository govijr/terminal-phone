import Foundation
import TerminalPhoneCore
import TerminalMacCore

@MainActor
extension PhoneCLI {
    static let mcpConfigUsage = "Usage: terminal-phone mcp install|uninstall [--claude] [--cursor] [--codex] [--command PATH] [--print]"

    /// Registers `terminal-phone mcp` with agent apps, only when the user asks. Nothing is changed during
    /// `self install` or any other command.
    func mcpConfigCommand(_ input: [String]) async throws {
        let args = try Arguments(input, flags: Set(AgentClient.allCases.map(\.rawValue) + ["print"]), options: ["command"])
        guard args.positionals.count == 1, let operation = args.positionals.first, ["install", "uninstall"].contains(operation) else {
            throw AgentError(.invalidRequest, Self.mcpConfigUsage)
        }
        let install = operation == "install"
        let environment = ProcessInfo.processInfo.environment
        // $HOME first, like the agent apps themselves, so a custom HOME edits the files those apps read.
        let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? FileManager.default.homeDirectoryForCurrentUser
        let command = args.options["command"]
            ?? AgentClientConfig.stableCommand(executable: Bundle.main.executableURL!, path: environment["PATH"])
        guard command.hasPrefix("/") else { throw AgentError(.invalidRequest, "--command must be an absolute path.") }

        var clients = AgentClient.allCases.filter { args.flags.contains($0.rawValue) }
        let chosen = !clients.isEmpty
        if !chosen {
            clients = AgentClient.allCases.filter { client in
                switch client {
                case .claude: return CommandRunner.executable("claude") != nil
                case .cursor, .codex: return FileManager.default.fileExists(atPath: client.configFile(home: home)!.deletingLastPathComponent().path)
                }
            }
            if !args.flags.contains("print") {
                guard !clients.isEmpty else {
                    throw AgentError(.notReady, "No Claude Code, Cursor or Codex setup found. Pass --claude, --cursor or --codex, or --print to see the entries.")
                }
                progress("Found: \(clients.map(\.displayName).joined(separator: ", ")). Pass --claude, --cursor or --codex to choose.")
            }
        }

        if args.flags.contains("print") {
            let shown = chosen ? clients : AgentClient.allCases
            try printJSON(["ok": true, "command": command,
                           "clients": shown.map { ["client": $0.rawValue, "file": $0.configFile(home: home)?.path ?? NSNull(),
                                                   "entry": AgentClientConfig.snippet(for: $0, command: command)] as [String: Any] }])
            return
        }
        if install, !FileManager.default.isExecutableFile(atPath: command) {
            throw AgentError(.notReady, "\(command) isn't an executable. Run terminal-phone self install first, or pass --command.")
        }

        var results: [[String: Any]] = []
        for client in clients {
            var result: [String: Any] = ["client": client.rawValue]
            do {
                switch client {
                case .claude:
                    guard let claude = CommandRunner.executable("claude") else {
                        throw Failure("The claude command wasn't found. Run: \(AgentClientConfig.snippet(for: .claude, command: command))")
                    }
                    // Replace any earlier entry (an old path, or one added by hand) instead of failing on the duplicate.
                    let removed = try await CommandRunner.run(claude, AgentClientConfig.claudeRemoveArguments, timeout: 30)
                    if install {
                        let added = try await CommandRunner.run(claude, AgentClientConfig.claudeAddArguments(command: command), timeout: 30)
                        guard added.status == 0 else { throw Failure("claude mcp add failed: \(added.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
                    }
                    result["changed"] = install || removed.status == 0
                    result["scope"] = "user"
                case .cursor:
                    let file = client.configFile(home: home)!
                    let existing = try? Data(contentsOf: file)
                    if !install && existing == nil { result["changed"] = false; break }
                    result["changed"] = try AgentClientConfig.write(try AgentClientConfig.cursor(existing: existing, command: install ? command : nil), to: file)
                    result["file"] = file.path
                case .codex:
                    let file = client.configFile(home: home)!
                    let existing = (try? String(contentsOf: file.resolvingSymlinksInPath(), encoding: .utf8))
                    if !install && existing == nil { result["changed"] = false; break }
                    let updated = AgentClientConfig.codex(existing: existing ?? "", command: install ? command : nil)
                    result["changed"] = try AgentClientConfig.write(Data(updated.utf8), to: file)
                    result["file"] = file.path
                }
                result["ok"] = true
            } catch {
                result["ok"] = false
                result["error"] = error.localizedDescription
            }
            results.append(result)
        }
        let ok = results.allSatisfy { $0["ok"] as? Bool == true }
        try printJSON(["ok": ok, "operation": operation, "command": command, "server": AgentClientConfig.serverName, "clients": results,
                       "next": install ? "Restart the agent app (or start a new session) to load the phone_* tools." : "Restart the agent app to unload the tools."])
        if !ok { exit(1) }
    }
}
