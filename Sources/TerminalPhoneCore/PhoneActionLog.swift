import Foundation

/// One input that reached a phone, from the viewer (a person) or an agent.
public struct PhoneActionLogEntry: Codable, Equatable {
    public let at: Date
    /// "viewer" for a person using the terminal viewer, "agent" for the agent API and MCP.
    public let source: String
    public let action: PhoneAction
    /// The element an agent's selector resolved to, so a recording can replay it by name.
    public let target: PhoneElement?
    /// "delivered", or "unknown" when the input may or may not have reached iOS.
    public let outcome: String
    public let error: String?
    public let requestId: String
    public init(at: Date = Date(), source: String, action: PhoneAction, target: PhoneElement?, outcome: String, error: String?, requestId: String) {
        self.at = at; self.source = source; self.target = target; self.outcome = outcome; self.error = error; self.requestId = requestId
        // Text typed into a secure field is never written to disk.
        if target?.secure == true, action.text != nil {
            var redacted = action; redacted.text = PhoneActionLog.redacted; self.action = redacted
        } else { self.action = action }
    }
}

/// An append-only JSON Lines file per phone, private to this user, rotated at a few megabytes.
public enum PhoneActionLog {
    public static let redacted = "<redacted>"
    public static let maxBytes = 4 << 20
    public static func url(in directory: URL) -> URL { directory.appendingPathComponent("actions.jsonl") }

    public static func append(_ entry: PhoneActionLogEntry, to url: URL) throws {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > maxBytes {
            let previous = url.appendingPathExtension("1")
            try? fm.removeItem(at: previous)
            try fm.moveItem(at: url, to: previous)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: PhoneAgentCoding.encoder().encode(entry) + Data([10]))
    }

    /// Entries oldest first, including the rotated file. Unreadable lines are skipped.
    public static func read(_ url: URL, since: Date? = nil) -> [PhoneActionLogEntry] {
        let decoder = PhoneAgentCoding.decoder()
        return [url.appendingPathExtension("1"), url].flatMap { file -> [PhoneActionLogEntry] in
            guard let data = try? Data(contentsOf: file) else { return [] }
            return data.split(separator: 10).compactMap { try? decoder.decode(PhoneActionLogEntry.self, from: Data($0)) }
        }.filter { since == nil || $0.at >= since! }
    }

    /// A short, readable line for the terminal.
    public static func describe(_ entry: PhoneActionLogEntry) -> String {
        let action = entry.action
        var text = action.kind.rawValue
        if let target = entry.target { text += " " + (target.identifier.map { "#\($0)" } ?? target.label.map { "“\($0)”" } ?? target.role) }
        else if let selector = action.target { text += " " + (selector.identifier.map { "#\($0)" } ?? selector.label.map { "“\($0)”" } ?? selector.ref ?? "") }
        if let points = action.coordinates { text += " " + points.map(String.init).joined(separator: ",") }
        if let direction = action.direction { text += " " + direction }
        if let value = action.text { text += " " + (value.count > 40 ? "“\(value.prefix(39))…”" : "“\(value)”") }
        if entry.outcome != "delivered" { text += " (\(entry.outcome)\(entry.error.map { ": \($0)" } ?? ""))" }
        return text
    }
}
