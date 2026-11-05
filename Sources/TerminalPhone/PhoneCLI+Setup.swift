import Foundation
import TerminalMacCore
import TerminalPhoneCore

@MainActor
extension PhoneCLI {
    var defaultName: String { (try? PhoneConfiguration.load(store: store).preferredPhone) ?? "default" }
    func rememberPhone(_ name: String) throws {
        var config = try PhoneConfiguration.load(store: store); config.preferredPhone = name; try config.save(store: store)
    }
    func setupCommand(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["yes", "check", "json"])
        guard args.positionals.isEmpty else { throw AgentError(.invalidRequest, "Usage: terminal-phone setup [--check] [--json]") }
        if !args.flags.contains("check") {
            progress("Checking Xcode, iOS and phone controls…")
            try await PhoneSetup(cli: self).ensureSimulator(allowDownload: true, managed: true)
        }
        let catalog = try? await catalog()
        let runtimes = catalog?.runtimes.filter { $0.isAvailable && $0.identifier.contains(".iOS-") }.map(\.version) ?? []
        let ready = !runtimes.isEmpty && touchAvailable
        if args.flags.contains("json") || isatty(STDOUT_FILENO) != 1 {
            try printJSON(["ok": ready, "version": PhoneAgentAPI.productVersion, "phone": defaultName,
                           "iOSRuntimes": runtimes, "touchReady": touchAvailable, "runtimeDirectory": PhoneDependencyPaths.root.path,
                           "next": ready ? "terminal-phone" : "terminal-phone setup"])
        } else {
            progress(ready ? "Ready. Run terminal-phone to open an interactive phone." : "Setup is incomplete. Run terminal-phone setup.")
        }
        if !ready { exit(1) }
    }

    func selfCommand(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["no-path", "skip-setup"], options: ["prefix"])
        guard args.positionals == ["install"] else { throw AgentError(.invalidRequest, "Usage: terminal-phone self install [--prefix PATH] [--no-path]") }
        let prefix = URL(fileURLWithPath: (args.options["prefix"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local").path) as String)
        guard args.options["prefix"] == nil || args.options["prefix"]!.hasPrefix("/") else { throw AgentError(.invalidRequest, "The install prefix must be an absolute path.") }
        if !args.flags.contains("skip-setup") { try await PhoneSetup(cli: self).ensureSimulator(allowDownload: true, managed: true) }
        try migrateRealDeviceRuntime()
        let source = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()
        _ = try await CommandRunner.checked("/usr/bin/codesign", ["--verify", "--strict", source.appendingPathComponent("terminal-phone").path])
        var profile: URL?
        if !args.flags.contains("no-path") {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let home = FileManager.default.homeDirectoryForCurrentUser
            if shell.hasSuffix("zsh") {
                let directory = ProcessInfo.processInfo.environment["ZDOTDIR"].map { URL(fileURLWithPath: $0) } ?? home
                profile = directory.appendingPathComponent(".zshrc").resolvingSymlinksInPath()
            } else if shell.hasSuffix("bash") { profile = home.appendingPathComponent(".bash_profile").resolvingSymlinksInPath() }
        }
        let installed = try PhoneInstaller.install(source: source, prefix: prefix, profile: profile)
        _ = try await CommandRunner.checked(installed.launcher, ["version"])
        try PhoneRuntimeRegistry.record([source.appendingPathComponent("terminal-phone").path, installed.runtime + "/terminal-phone"])
        for name in (try? store.names()) ?? [] {
            _ = try? await PhoneAgentClient.stop(cli: self, name: name)
        }
        progress("Installed terminal-phone \(PhoneAgentAPI.productVersion).")
        progress(installed.profileUpdated ? "Open a new terminal and run: terminal-phone" : "Run: \(installed.launcher)")
        try printJSON(try JSONSerialization.jsonObject(with: JSONEncoder().encode(installed)))
    }

    func connectCommand(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["allow-input", "no-view", "view-only"], options: ["device", "team"])
        guard args.positionals.count <= 1 else { throw AgentError(.invalidRequest, "Usage: terminal-phone connect [NAME] [--device ID] [--team TEAM]") }
        try await PhoneSetup(cli: self).ensureXcode()
        let devices = try await PhoneDevices.list(self).filter { $0.pairing == "paired" }
        guard !devices.isEmpty else { throw AgentError(.notReady, "Connect your iPhone by USB, unlock it, tap Trust, then run terminal-phone connect again.") }
        let selected: ConnectedDevice
        if let query = args.options["device"] {
            let matches = devices.filter { $0.matches(query) }
            guard matches.count == 1 else { throw AgentError(.invalidRequest, "Choose one exact iPhone name or identifier from terminal-phone device list.") }
            selected = matches[0]
        } else if devices.count == 1 { selected = devices[0] }
        else {
            guard isatty(STDIN_FILENO) == 1 else { throw AgentError(.invalidRequest, "Several iPhones are connected. Pass --device with one identifier.") }
            for (i, device) in devices.enumerated() { progress("  \(i + 1). \(device.name) — \(device.marketingName)") }
            FileHandle.standardError.write(Data("Choose an iPhone: ".utf8))
            guard let index = readLine().flatMap(Int.init), devices.indices.contains(index - 1) else { throw AgentError(.invalidRequest, "No iPhone was selected.") }
            selected = devices[index - 1]
        }
        guard selected.developerMode == "enabled" else { throw AgentError(.notReady, "On \(selected.name), enable Settings → Privacy & Security → Developer Mode, restart it, then run terminal-phone connect again.") }
        let registered = try store.names().first { (try? store.load($0))?.udid == selected.identifier }
        let name = try named([args.positionals.first ?? registered ?? "iphone"])
        let existing = try? store.load(name)
        if let existing, existing.udid != selected.identifier { throw AgentError(.invalidRequest, "'\(name)' already belongs to another phone. Choose a different name.") }
        guard !(args.flags.contains("view-only") && args.flags.contains("allow-input")) else {
            throw AgentError(.invalidRequest, "Choose either --view-only or --allow-input.")
        }
        // --view-only is an explicit decision and withdraws an earlier grant.
        var allowed = !args.flags.contains("view-only") && (existing?.acceptsInput == true || args.flags.contains("allow-input"))
        if existing?.acceptsInput == true && !allowed { progress("Input withdrawn for \(name); it is now view-only.") }
        if !allowed && !args.flags.contains("view-only") && isatty(STDIN_FILENO) == 1 {
            progress("Allow terminal-phone and your connected agents to tap, type and navigate on \(selected.name)?")
            FileHandle.standardError.write(Data("Allow control? [y/N] ".utf8))
            allowed = ["y", "yes"].contains(readLine()?.lowercased() ?? "")
        }
        let phone = try Phone(name: name, device: selected, allowInput: allowed)
        try store.save(phone)
        try await prepareRealDevice(phone, team: args.options["team"])
        var command = [name, "--device-id", selected.identifier]
        if allowed { command.append("--allow-input") }
        if args.flags.contains("no-view") { command.append("--no-view") }
        if !allowed { command.append("--read-only") }
        try rememberPhone(name)
        try await up(command)
    }

    func prepareRealDevice(_ phone: Phone, team explicit: String? = nil) async throws {
        try migrateRealDeviceRuntime()
        if PhoneDevices.xctestrun() != nil && explicit == nil { return }
        var config = try PhoneConfiguration.load(store: store)
        var team = explicit ?? config.signingTeam
        if team == nil, isatty(STDIN_FILENO) == 1 {
            progress("Xcode needs your development team once to sign the iPhone helper.")
            FileHandle.standardError.write(Data("Team ID from Xcode → Settings → Accounts: ".utf8))
            team = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let team, !team.isEmpty else { throw AgentError(.notReady, "Finish iPhone signing once with terminal-phone connect, or pass --team TEAM_ID.") }
        _ = try await PhoneDevices.setup(self, phone: phone, team: team, bundlePrefix: "com.terminalphone.\(team.lowercased())")
        config.signingTeam = team; try config.save(store: store)
    }

    private func migrateRealDeviceRuntime() throws {
        let fm = FileManager.default
        let root = PhoneDevices.dependencies
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if PhoneDevices.xctestrun() == nil, !fm.fileExists(atPath: root.appendingPathComponent("wda-build").path), let legacy = PhoneDependencyPaths.bundled?.appendingPathComponent("wda-build"), fm.fileExists(atPath: legacy.path), legacy.standardizedFileURL != root.appendingPathComponent("wda-build").standardizedFileURL {
            progress("Reusing your existing iPhone signing setup…")
            try fm.copyItem(at: legacy, to: root.appendingPathComponent("wda-build"))
        }
    }
}
