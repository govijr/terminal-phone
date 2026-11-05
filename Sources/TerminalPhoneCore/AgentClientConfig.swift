import Foundation
import TerminalMacCore

/// Agent apps that `terminal-phone mcp install` can register the MCP server with.
public enum AgentClient: String, CaseIterable, Codable, Sendable {
    case claude, cursor, codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        }
    }

    /// The config file this CLI edits itself. Claude Code is configured through its own `claude mcp` command.
    public func configFile(home: URL) -> URL? {
        switch self {
        case .claude: return nil
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        case .codex: return home.appendingPathComponent(".codex/config.toml")
        }
    }
}

/// Pure config edits for agent apps, kept separate from file and process I/O so they can be tested.
/// Every edit touches only the `terminal-phone` entry and leaves the user's other servers untouched.
public enum AgentClientConfig {
    public static let serverName = "terminal-phone"
    public static let launcherMarker = "# terminal-phone launcher v1"

    /// The command agents should launch: an installed `terminal-phone` launcher on PATH survives upgrades,
    /// unlike the versioned runtime folder the running binary lives in.
    public static func stableCommand(executable: URL, path: String?, fileManager: FileManager = .default) -> String {
        for directory in (path ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("terminal-phone")
            guard fileManager.isExecutableFile(atPath: candidate.path),
                  let head = try? FileHandle(forReadingFrom: candidate).read(upToCount: 256),
                  String(decoding: head, as: UTF8.self).contains(launcherMarker) else { continue }
            return candidate.path
        }
        return executable.resolvingSymlinksInPath().path
    }

    public static func claudeAddArguments(command: String) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", command, "mcp"]
    }

    public static let claudeRemoveArguments = ["mcp", "remove", "--scope", "user", serverName]

    /// Adds (command != nil) or removes (command == nil) the server in Cursor's `mcp.json`.
    public static func cursor(existing: Data?, command: String?) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ [9, 10, 13, 32].contains($0) }) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw Failure("Cursor's mcp.json isn't a JSON object, so it was left unchanged. Fix it or pass --print and add the entry yourself.")
            }
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
            throw Failure("Cursor's mcp.json has an mcpServers value that isn't an object, so it was left unchanged.")
        }
        if let command { servers[serverName] = ["command": command, "args": ["mcp"]] } else { servers[serverName] = nil }
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
    }

    /// Adds (command != nil) or removes (command == nil) the `[mcp_servers.terminal-phone]` table in Codex's `config.toml`.
    public static func codex(existing: String, command: String?) -> String {
        let headers: Set<String> = ["[mcp_servers.terminal-phone]", "[mcp_servers.\"terminal-phone\"]", "[mcp_servers.'terminal-phone']"]
        let subtables = ["[mcp_servers.terminal-phone.", "[mcp_servers.\"terminal-phone\".", "[mcp_servers.'terminal-phone'."]
        var kept: [String] = [], skipping = false
        for line in existing.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                let header = trimmed.split(separator: "#", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? trimmed
                skipping = headers.contains(header) || subtables.contains { header.hasPrefix($0) }
            }
            if !skipping { kept.append(line) }
        }
        var text = kept.joined(separator: "\n")
        while text.hasSuffix("\n\n") { text.removeLast() }
        guard let command else { return text.isEmpty || text.hasSuffix("\n") ? text : text + "\n" }
        if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
        return text + "[mcp_servers.terminal-phone]\ncommand = \(tomlString(command))\nargs = [\"mcp\"]\n"
    }

    /// The entry each app needs, for `--print` and for doing it by hand.
    public static func snippet(for client: AgentClient, command: String) -> String {
        switch client {
        case .claude: return (["claude"] + claudeAddArguments(command: command)).map(shellQuote).joined(separator: " ")
        case .cursor: return String(decoding: (try? cursor(existing: nil, command: command)) ?? Data(), as: UTF8.self)
        case .codex: return codex(existing: "", command: command)
        }
    }

    /// Writes a config file: follows a dotfile-manager symlink to the real file, keeps a backup of the
    /// previous contents and its permissions, and does nothing when the contents wouldn't change.
    @discardableResult
    public static func write(_ data: Data, to link: URL, fileManager: FileManager = .default) throws -> Bool {
        let file = link.resolvingSymlinksInPath()
        let old = try? Data(contentsOf: file)
        if old == data { return false }
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var permissions = 0o600
        if old != nil {
            permissions = (try? fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            try fileManager.copyItem(at: file, to: file.appendingPathExtension("terminal-phone-backup-\(UUID().uuidString.prefix(8))"))
        }
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        return true
    }

    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func shellQuote(_ value: String) -> String {
        value.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
