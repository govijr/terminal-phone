import Foundation
import Darwin
import CryptoKit
import TerminalMacCore
import TerminalPhoneCore

/// Owns installation and discovery. Device adapters never run package managers or prompt users.
@MainActor
final class PhoneSetup {
    private let cli: PhoneCLI
    private let fm = FileManager.default
    init(cli: PhoneCLI) { self.cli = cli }

    static func configureEnvironment() {
        let configured = try? PhoneConfiguration.load().developerDirectory
        let existing = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        let applications = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        let candidates = [existing, configured, "/Applications/Xcode.app/Contents/Developer"].compactMap { $0 } +
            applications.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted().reversed().map { "/Applications/\($0)/Contents/Developer" }
        if let selected = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/usr/bin/simctl") }) {
            setenv("DEVELOPER_DIR", selected, 1)
        }
    }

    func ensureSimulator(allowDownload: Bool, managed: Bool = false) async throws {
        try await ensureXcode()
        if !(try await cli.catalog()).runtimes.contains(where: { $0.isAvailable && $0.identifier.contains(".iOS-") }) {
            guard allowDownload else { throw AgentError(.notReady, "The iOS simulator runtime is missing.", recovery: "Run terminal-phone setup once to download it automatically.") }
            cli.progress("Downloading the iOS simulator from Apple. This can take several minutes…")
            _ = try await CommandRunner.checked(cli.xcrun, ["xcodebuild", "-downloadPlatform", "iOS", "-architectureVariant", "arm64"], timeout: 7200)
            guard (try await cli.catalog()).runtimes.contains(where: { $0.isAvailable && $0.identifier.contains(".iOS-") }) else {
                throw AgentError(.notReady, "Apple's runtime download did not produce a usable iOS simulator.", recovery: "Open Xcode → Settings → Components, finish installing iOS, then run terminal-phone again.")
            }
        }
        try await ensureAutomation(allowDownload: allowDownload, managed: managed)
    }

    func ensureXcode() async throws {
        Self.configureEnvironment()
        guard ProcessInfo.processInfo.environment["DEVELOPER_DIR"] != nil else {
            throw AgentError(.notReady, "Install Xcode from the Mac App Store and open it once. terminal-phone will find it automatically.", recovery: "Open https://apps.apple.com/app/xcode/id497799835, finish Xcode's first launch, then run terminal-phone again.")
        }
        let version = try await CommandRunner.run(cli.xcrun, ["xcodebuild", "-version"], timeout: 30)
        let text = String(decoding: version.output, as: UTF8.self)
        guard version.status == 0 else {
            throw AgentError(.notReady, "Xcode needs its first-launch setup. Open Xcode and finish Apple's license/component prompts.", recovery: "After Xcode finishes, run terminal-phone again.")
        }
        guard let major = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).dropFirst().first.flatMap({ Int($0.split(separator: ".")[0]) }), major >= 26 else {
            throw AgentError(.notReady, "This phone-control runtime needs Xcode 26 or newer. Update Xcode, then run terminal-phone again.")
        }
        let firstLaunch = try await CommandRunner.run(cli.xcrun, ["xcodebuild", "-checkFirstLaunchStatus"], timeout: 30)
        guard firstLaunch.status == 0 else {
            throw AgentError(.notReady, "Xcode has unfinished first-launch components. Open Xcode to finish installing them.", recovery: "Apple may require an administrator or license confirmation. Then rerun terminal-phone.")
        }
        var config = try PhoneConfiguration.load(store: cli.store)
        config.developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        try config.save(store: cli.store)
    }

    func ensureAutomation(allowDownload: Bool, managed: Bool = false) async throws {
        let root = PhoneDependencyPaths.root
        let wantedClient = root.appendingPathComponent("idb-venv/bin/idb")
        let wantedCompanion = root.appendingPathComponent("companion/idb_companion")
        if !managed, cli.touchAvailable, let idb = cli.idb, await validClient(idb) { return }
        if managed, fm.isExecutableFile(atPath: wantedCompanion.path), await validClient(wantedClient.path) { return }
        guard allowDownload else { throw AgentError(.notReady, "Phone touch control needs its local runtime.", recovery: "Run terminal-phone setup. It installs everything automatically without Homebrew.") }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else { throw AgentError(.unsupported, "Simulator control requires macOS 15 or newer.") }
        #if !arch(arm64)
        throw AgentError(.unsupported, "This bundled phone-control runtime requires an Apple silicon Mac.")
        #endif
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock: FileLock
        let deadline = Date().addingTimeInterval(120)
        var acquired: FileLock?
        while acquired == nil && Date() < deadline {
            acquired = try? FileLock(root.appendingPathComponent("setup.lock"))
            if acquired == nil { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        guard let acquired else { throw AgentError(.notReady, "Another terminal-phone setup is still running. Retry shortly.") }
        lock = acquired; defer { withExtendedLifetime(lock) {} }
        if !fm.isExecutableFile(atPath: wantedCompanion.path) {
            cli.progress("Setting up phone touch control…")
            let archive = try await download(name: "idb-companion-1.7.8.tar.gz",
                url: "https://github.com/facebook/idb/releases/download/v1.7.8/idb-companion.macos-arm64.tar.gz",
                sha256: "44369a2df0b62e3a1764de61bd09280999c7e9b27ea8f20bff1ea3a9db0302a2")
            try await extract(archive, destination: root.appendingPathComponent("companion"), expected: "idb_companion")
        }
        if !(await validClient(wantedClient.path)) {
            let python = root.appendingPathComponent("python/bin/python3")
            if !fm.isExecutableFile(atPath: python.path) {
                cli.progress("Setting up the private phone runtime…")
                let archive = try await download(name: "python-3.13.18.tar.gz",
                    url: "https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.13.18%2B20261026-aarch64-apple-darwin-install_only_stripped.tar.gz",
                    sha256: "8392b6ea51d94391befb2c31ebe75463f045d0b69dfcf5e1bb3234e1f5fa3405")
                try await extract(archive, destination: root.appendingPathComponent("python"), expected: "bin/python3", wrapper: "python")
            }
            let requirements = PhoneDependencyPaths.resources.appendingPathComponent("phone-idb-requirements.txt")
            guard fm.fileExists(atPath: requirements.path) else { throw AgentError(.notReady, "The CLI package is missing its runtime requirements. Reinstall the full terminal-phone package.") }
            let staging = root.appendingPathComponent(".client-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            cli.progress("Installing phone-control components into the private runtime…")
            _ = try await CommandRunner.checked(python.path, ["-m", "venv", staging.path], timeout: 120)
            _ = try await CommandRunner.checked(staging.appendingPathComponent("bin/python3").path,
                ["-m", "pip", "install", "--disable-pip-version-check", "--only-binary=:all:", "--require-hashes", "--no-deps", "-r", requirements.path], timeout: 600)
            let destination = root.appendingPathComponent("idb-venv")
            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: root.appendingPathComponent("idb-venv.previous-\(UUID().uuidString.prefix(8))"))
            }
            try fm.moveItem(at: staging, to: destination)
        }
        guard await validClient(wantedClient.path) else { throw AgentError(.notReady, "The private phone runtime did not pass its startup check.", recovery: "Run terminal-phone setup again; completed downloads are reused.") }
        _ = try await CommandRunner.checked(wantedCompanion.path, ["--version"], timeout: 15)
    }

    private func validClient(_ path: String) async -> Bool {
        guard fm.isExecutableFile(atPath: path) else { return false }
        let python = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("python3")
        guard fm.isExecutableFile(atPath: python.path) else { return false }
        return (try? await CommandRunner.run(python.path,
            ["-c", "from idb.grpc.client import Client; from idb.common.types import HIDButtonType; import grpclib"], timeout: 20).status) == 0
    }

    private func download(name: String, url: String, sha256: String) async throws -> URL {
        let downloads = PhoneDependencyPaths.root.appendingPathComponent("downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let destination = downloads.appendingPathComponent(name)
        func valid(_ path: URL) -> Bool {
            guard let data = try? Data(contentsOf: path, options: .mappedIfSafe) else { return false }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
        }
        if valid(destination) { return destination }
        let partial = downloads.appendingPathComponent(name + ".partial")
        cli.progress("Downloading \(name)…")
        _ = try await CommandRunner.checked("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "2", "--connect-timeout", "20", "--output", partial.path, url], timeout: 900)
        guard valid(partial) else { try? fm.removeItem(at: partial); throw AgentError(.notReady, "A phone-runtime download failed its checksum. Run setup again.") }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: partial, to: destination)
        return destination
    }
    private func extract(_ archive: URL, destination: URL, expected: String, wrapper: String? = nil) async throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".unpack-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        _ = try await CommandRunner.checked("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path], timeout: 120)
        let source = wrapper.map { staging.appendingPathComponent($0) } ?? staging
        guard fm.isExecutableFile(atPath: source.appendingPathComponent(expected).path) else { throw AgentError(.notReady, "The downloaded runtime has an unexpected layout.") }
        if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: destination.appendingPathExtension("previous-\(UUID().uuidString.prefix(8))")) }
        try fm.moveItem(at: source, to: destination)
    }
}
