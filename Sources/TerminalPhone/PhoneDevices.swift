import Foundation
import TerminalMacCore
import TerminalPhoneCore

/// Real iPhones: discovery through CoreDevice, and the WebDriverAgent runner that drives them.
@MainActor
enum PhoneDevices {
    static let wdaVersion = "v16.15.3"
    static let wdaArchiveSHA256 = "a232b9faaa47e33d5348dea362910a772ebf6f3b405d2a680ba9d488e30266e5"

    static var dependencies: URL {
        PhoneDependencyPaths.root
    }

    static func list(_ cli: PhoneCLI) async throws -> [ConnectedDevice] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-phone-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await CommandRunner.checked(cli.xcrun, ["devicectl", "list", "devices", "--quiet", "--json-output", output.path], timeout: 30)
        return try ConnectedDevice.parse(Data(contentsOf: output)).filter(\.isIPhone)
    }
    static func find(_ cli: PhoneCLI, _ phone: Phone) async throws -> ConnectedDevice {
        guard let device = try await list(cli).first(where: { $0.identifier.caseInsensitiveCompare(phone.udid) == .orderedSame }) else {
            throw Failure("The iPhone registered as '\(phone.name)' is no longer paired with this Mac. Pair it in Xcode → Window → Devices and Simulators.")
        }
        return device
    }

    /// The last ready client per phone. One `up` or `view` connects several times in a row;
    /// reusing it skips the device lookup, the WDA probe, and the session lookup on each.
    private static var recent: [String: (agent: WebDriverAgent, at: Date)] = [:]
    private static let reuseWindow: TimeInterval = 15

    /// Drops the remembered client, e.g. after the tunnel moved to a new address.
    static func forget(_ phone: Phone) { recent[phone.udid.uppercased()] = nil }

    /// A ready WebDriverAgent client, starting the runner if it isn't already serving.
    static func connect(_ cli: PhoneCLI, _ phone: Phone, progress: Bool = true) async throws -> WebDriverAgent {
        let key = phone.udid.uppercased()
        if let hit = recent[key], Date().timeIntervalSince(hit.at) < reuseWindow { return hit.agent }
        let agent = try await open(cli, phone, progress: progress)
        recent[key] = (agent, Date())
        return agent
    }

    private static func open(_ cli: PhoneCLI, _ phone: Phone, progress: Bool) async throws -> WebDriverAgent {
        var device = try await find(cli, phone)
        if !device.reachable, device.pairing == "paired" {
            // CoreDevice opens its USB/Wi-Fi tunnel on demand; asking for device details opens it.
            let details = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-phone-device-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: details) }
            _ = try? await CommandRunner.run(cli.xcrun, ["devicectl", "device", "info", "details", "--device", phone.udid, "--quiet", "--json-output", details.path], timeout: 30)
            device = try await find(cli, phone)
        }
        guard device.developerMode == "enabled" else { throw Failure("Turn on Developer Mode on \(device.name): Settings → Privacy & Security → Developer Mode.") }
        guard device.reachable, let host = device.tunnelAddress else {
            throw Failure("\(device.name) isn't connected. Unlock it and keep it on the same Wi-Fi as this Mac, or plug it in by USB.")
        }
        let agent = WebDriverAgent(host: host)
        if await agent.ready() { return agent }
        guard let testrun = xctestrun() else { throw Failure("WebDriverAgent isn't built yet. Run: terminal-phone device setup \(phone.name) --team YOUR_TEAM_ID") }
        let log = try cli.store.directory(phone.name).appendingPathComponent("webdriveragent.log")
        try startRunner(cli, phone, testrun: testrun, log: log)
        if progress { cli.progress("Starting WebDriverAgent on \(device.name)…") }
        var warned = false
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if await agent.ready(timeout: 2) { return agent }
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if !warned, text.contains("Unlock") || text.contains("is locked") { warned = true; if progress { cli.progress("Unlock \(device.name) to continue…") } }
            if text.contains("** TEST FAILED **") || text.contains("Testing failed") || text.contains("** TEST EXECUTE FAILED **") {
                throw Failure("WebDriverAgent failed to start on \(device.name). Details: \(log.path)")
            }
            // A refused connection returns at once, so probing often costs little and catches readiness sooner.
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw Failure("WebDriverAgent didn't start within two minutes. Is \(device.name) unlocked? Details: \(log.path)")
    }

    static func xctestrun() -> URL? {
        let products = dependencies.appendingPathComponent("wda-build/Build/Products")
        return (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "xctestrun" && $0.lastPathComponent.contains("iphoneos") }
    }

    /// XCTest hosts WDA; the runner keeps serving after this command exits, until `stop`.
    private static func startRunner(_ cli: PhoneCLI, _ phone: Phone, testrun: URL, log: URL) throws {
        guard let udid = phone.hardwareUDID, !udid.isEmpty else { throw Failure("Registration for '\(phone.name)' has no hardware UDID; register it again") }
        stopRunner(cli, phone)
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        // nohup keeps the runner alive when the terminal that started it closes.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/usr/bin/xcrun", "xcodebuild", "test-without-building", "-xctestrun", testrun.path, "-destination", "id=\(udid)"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
        try process.run()
        try String(process.processIdentifier).write(to: pidFile(cli, phone), atomically: true, encoding: .utf8)
    }
    private static func pidFile(_ cli: PhoneCLI, _ phone: Phone) throws -> URL {
        try cli.store.directory(phone.name).appendingPathComponent("webdriveragent.pid")
    }
    /// Ends the runner this tool started. Returns whether one was running.
    @discardableResult
    static func stopRunner(_ cli: PhoneCLI, _ phone: Phone) -> Bool {
        forget(phone)
        guard let file = try? pidFile(cli, phone), let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        try? FileManager.default.removeItem(at: file)
        // Only signal the process if it is still our xcodebuild, not a reused PID.
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard size > 0, info.pbi_uid == getuid(), ["xcodebuild", "nohup"].contains(name) else { return false }
        kill(pid, SIGINT)
        return true
    }

    /// Downloads the pinned WebDriverAgent source, signs it with the given team, and installs it.
    static func setup(_ cli: PhoneCLI, phone: Phone?, team: String, bundlePrefix: String) async throws -> [String: Any] {
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw Failure("--team must be a 10-character Apple Developer team ID") }
        guard bundlePrefix.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { throw Failure("--bundle-prefix must look like com.example.terminalphone") }
        let fm = FileManager.default
        try fm.createDirectory(at: dependencies, withIntermediateDirectories: true)
        let archive = dependencies.appendingPathComponent("wda-\(wdaVersion).tar.gz")
        if !fm.fileExists(atPath: archive.path) {
            cli.progress("Downloading WebDriverAgent \(wdaVersion)…")
            _ = try await CommandRunner.checked("/usr/bin/curl", ["-fsSL", "-o", archive.path, "https://codeload.github.com/appium/WebDriverAgent/tar.gz/refs/tags/\(wdaVersion)"], timeout: 300)
        }
        let digest = String(decoding: try await CommandRunner.checked("/usr/bin/shasum", ["-a", "256", archive.path]), as: UTF8.self).prefix(64)
        guard digest == wdaArchiveSHA256 else { try? fm.removeItem(at: archive); throw Failure("WebDriverAgent download failed its checksum; try again") }
        // Always start from a clean tree so a new bundle prefix applies to every target.
        let source = dependencies.appendingPathComponent("WebDriverAgent")
        try? fm.removeItem(at: source); try fm.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try await CommandRunner.checked("/usr/bin/tar", ["-xzf", archive.path, "-C", source.path, "--strip-components", "1"], timeout: 120)
        let project = source.appendingPathComponent("WebDriverAgent.xcodeproj/project.pbxproj")
        var text = try String(contentsOf: project, encoding: .utf8)
        for target in ["WebDriverAgentLib", "WebDriverAgentRunner"] {
            text = text.replacingOccurrences(of: "PRODUCT_BUNDLE_IDENTIFIER = com.facebook.\(target);", with: "PRODUCT_BUNDLE_IDENTIFIER = \(bundlePrefix).\(target);")
        }
        try text.write(to: project, atomically: true, encoding: .utf8)
        cli.progress("Building and signing WebDriverAgent with team \(team) (a few minutes)…")
        let build = dependencies.appendingPathComponent("wda-build")
        try? fm.removeItem(at: build)
        let result = try await CommandRunner.run("/usr/bin/xcrun", ["xcodebuild", "build-for-testing", "-project", source.appendingPathComponent("WebDriverAgent.xcodeproj").path,
                                                                    "-scheme", "WebDriverAgentRunner", "-destination", "generic/platform=iOS", "-derivedDataPath", build.path,
                                                                    "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=\(team)", "CODE_SIGN_STYLE=Automatic"], timeout: 1800)
        try? result.output.write(to: dependencies.appendingPathComponent("wda-build.log"))
        guard result.status == 0, xctestrun() != nil else {
            let errors = String(decoding: result.output, as: UTF8.self).split(separator: "\n").filter { $0.contains("error:") }.prefix(3).joined(separator: "\n")
            throw Failure("WebDriverAgent build failed. \(errors.isEmpty ? "See \(dependencies.path)/wda-build.log" : errors)")
        }
        var installed: String?
        if let phone {
            let app = build.appendingPathComponent("Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app")
            cli.progress("Installing on \(phone.displayModel)…")
            _ = try await CommandRunner.checked(cli.xcrun, ["devicectl", "device", "install", "app", "--device", phone.udid, app.path], timeout: 300)
            installed = phone.name
            stopRunner(cli, phone)
        }
        return ["ok": true, "version": wdaVersion, "team": team, "bundleIdentifier": "\(bundlePrefix).WebDriverAgentRunner.xctrunner",
                "installedOn": installed as Any? ?? NSNull(), "xctestrun": xctestrun()?.path as Any? ?? NSNull()]
    }
}
