import Foundation

public struct PhoneConfiguration: Codable, Equatable {
    public var preferredPhone: String?
    public var developerDirectory: String?
    public var signingTeam: String?
    /// Frame finish per phone name, as `FrameFinish` raw values.
    public var frames: [String: String]?
    public func frame(for phone: String) -> FrameFinish? { frames?[phone].flatMap(FrameFinish.init(rawValue:)) }
    /// The viewer's App Store panel settings.
    public var appStore: AppStoreSettings?
    public mutating func setFrame(_ finish: FrameFinish, for phone: String) { var all = frames ?? [:]; all[phone] = finish.rawValue; frames = all }
    public init(preferredPhone: String? = nil, developerDirectory: String? = nil, signingTeam: String? = nil) {
        self.preferredPhone = preferredPhone; self.developerDirectory = developerDirectory; self.signingTeam = signingTeam
    }
    public static func load(store: PhoneStore = PhoneStore()) throws -> PhoneConfiguration {
        let url = store.root.appendingPathComponent("configuration.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return PhoneConfiguration() }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        if let name = config.preferredPhone { try validatePhoneName(name) }
        return config
    }
    public func save(store: PhoneStore = PhoneStore()) throws {
        if let name = preferredPhone { try validatePhoneName(name) }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = store.root.appendingPathComponent("configuration.json")
        try JSONEncoder().encode(self).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    private static func validatePhoneName(_ name: String) throws {
        guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$", options: .regularExpression) != nil else {
            throw AgentError(.invalidRequest, "Invalid configured phone name.")
        }
    }
    private func validatePhoneName(_ name: String) throws { try Self.validatePhoneName(name) }
}

public enum PhoneDependencyPaths {
    public static var root: URL {
        ProcessInfo.processInfo.environment["TERMINAL_PHONE_DEPENDENCIES"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/terminal-phone/dependencies")
    }
    public static var bundled: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("dependencies")
    }
    public static var resources: URL {
        Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("resources")
    }
}

/// Only explicitly installed, signature-verified CLI paths may retire an older local host.
public enum PhoneRuntimeRegistry {
    public static func paths() -> [String] {
        let file = PhoneDependencyPaths.root.appendingPathComponent("installed-runtimes.json")
        guard let data = try? Data(contentsOf: file), let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths.filter { $0.hasPrefix("/") }
    }
    public static func record(_ additions: [String]) throws {
        let root = PhoneDependencyPaths.root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var known = paths()
        for path in additions where path.hasPrefix("/") && !known.contains(path) { known.append(path) }
        try JSONEncoder().encode(Array(known.suffix(64))).write(to: root.appendingPathComponent("installed-runtimes.json"), options: .atomic)
    }
}
