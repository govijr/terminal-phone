import Foundation
import CryptoKit
import TerminalMacCore

/// Installs only public runtime files. Personal device signing artifacts are never packaged.
public enum PhoneInstaller {
    public struct Result: Codable {
        public let launcher: String
        public let runtime: String
        public let profileUpdated: Bool
    }
    public static func install(source: URL, prefix: URL, profile: URL? = nil) throws -> Result {
        let fm = FileManager.default
        let required = ["terminal-phone", "resources/phone-agent-worker.py", "resources/phone-viewer-worker.py", "resources/phone-idb-requirements.txt"]
        for item in required where !fm.fileExists(atPath: source.appendingPathComponent(item).path) {
            throw AgentError(.notReady, "The CLI package is incomplete: \(item). Extract the full package or rebuild it.")
        }
        let binary = try Data(contentsOf: source.appendingPathComponent("terminal-phone"))
        var hasher = SHA256()
        hasher.update(data: binary)
        for directory in ["resources", "agent"] {
            let folder = source.appendingPathComponent(directory)
            let files = (fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path }
            for file in files {
                hasher.update(data: Data(file.path.dropFirst(source.path.count + 1).utf8) + Data([0]))
                hasher.update(data: Data(SHA256.hash(data: try Data(contentsOf: file))))
            }
        }
        let digest = hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        let library = prefix.appendingPathComponent("lib/terminal-phone")
        let bin = prefix.appendingPathComponent("bin")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let lock = try FileLock(library.appendingPathComponent("install.lock"))
        defer { withExtendedLifetime(lock) {} }
        let launcher = bin.appendingPathComponent("terminal-phone")
        if fm.fileExists(atPath: launcher.path) {
            let old = try String(contentsOf: launcher, encoding: .utf8)
            guard old.contains("# terminal-phone launcher v1") else { throw AgentError(.notReady, "An unrelated file already exists at \(launcher.path). Choose another --prefix.") }
        }
        let destination = library.appendingPathComponent("\(PhoneAgentAPI.productVersion)-\(digest)")
        if !fm.fileExists(atPath: destination.path) {
            let staging = library.appendingPathComponent(".install-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: staging) }
            for item in ["terminal-phone", "resources", "agent"] where fm.fileExists(atPath: source.appendingPathComponent(item).path) {
                try fm.copyItem(at: source.appendingPathComponent(item), to: staging.appendingPathComponent(item))
            }
            guard try Data(contentsOf: staging.appendingPathComponent("terminal-phone")) == binary else { throw AgentError(.notReady, "The installed binary did not match its source.") }
            try fm.moveItem(at: staging, to: destination)
        }
        let script = "#!/bin/sh\n# terminal-phone launcher v1\nexec \(quote(destination.appendingPathComponent("terminal-phone").path)) \"$@\"\n"
        try Data(script.utf8).write(to: launcher, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        var changed = false
        if let link = profile {
            // Dotfile managers (stow, chezmoi, a dotfiles repo) symlink ~/.zshrc. Edit the real file
            // so an atomic write doesn't replace the user's symlink with a detached copy.
            let profile = link.resolvingSymlinksInPath()
            let oldPermissions = (try? fm.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            let existing = fm.fileExists(atPath: profile.path) ? try String(contentsOf: profile, encoding: .utf8) : ""
            let marker = "# terminal-phone command path"
            if !existing.contains(marker) && !existing.contains(bin.path) {
                if fm.fileExists(atPath: profile.path) {
                    try fm.copyItem(at: profile, to: profile.appendingPathExtension("terminal-phone-backup-\(UUID().uuidString.prefix(8))"))
                }
                let addition = "\n\(marker)\nexport PATH=\(quote(bin.path)):\"$PATH\"\n"
                try Data((existing + addition).utf8).write(to: profile, options: .atomic)
                try fm.setAttributes([.posixPermissions: oldPermissions], ofItemAtPath: profile.path)
                changed = true
            }
        }
        return Result(launcher: launcher.path, runtime: destination.path, profileUpdated: changed)
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
