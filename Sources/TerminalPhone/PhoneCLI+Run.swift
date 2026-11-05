import Foundation
import TerminalMacCore
import TerminalPhoneCore

/// `run` builds the Xcode project in this folder, installs it, launches it and (optionally) keeps
/// doing so on every save. `logs` streams the app's output beside the phone.
extension PhoneCLI {
    struct XcodeApp {
        let container: [String]   // ["-project", path] or ["-workspace", path]
        let scheme: String
        let configuration: String
        let root: URL             // the folder to watch
    }

    func runCommand(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["watch", "no-view"], options: ["project", "workspace", "scheme", "configuration", "split"])
        let name = try named(args.positionals), saved = try store.load(name)
        let split = try args.options["split"].map { value -> SplitDirection in
            guard let direction = SplitDirection(rawValue: value) else { throw Failure("--split must be right, left, down or up") }
            return direction
        }
        if saved.isDevice {
            guard saved.acceptsInput else { throw AgentError(.inputDisabled, "Installing on '\(name)' needs input. Run terminal-phone connect \(name).") }
        } else { try await ensureBooted(saved) }
        let app = try await xcodeApp(args)
        let derived = try store.directory(name).appendingPathComponent("DerivedData")
        progress("Reading build settings for \(app.scheme)…")
        let (bundle, product) = try await appProduct(app, phone: saved, derived: derived)
        try await buildInstallLaunch(app, phone: saved, derived: derived, product: product, bundle: bundle)
        try? bundle.write(to: store.directory(name).appendingPathComponent("last-app"), atomically: true, encoding: .utf8)

        if let split {
            try rememberPhone(name)
            _ = try await TerminalSplit.open(name: name, direction: split)
        } else if !args.flags.contains("watch"), !args.flags.contains("no-view"), PhoneViewer.supportsCurrentTerminal {
            try rememberPhone(name)
            try await PhoneViewer(cli: self, phone: saved, screen: viewScreen(saved), graphics: nil, readOnly: false, cellSize: nil).run()
            return
        }
        guard args.flags.contains("watch") else {
            try printJSON(["ok": true, "name": name, "scheme": app.scheme, "bundleId": bundle, "app": product.path]); return
        }
        if split == nil { progress("Tip: terminal-phone view \(name) --split right shows the phone beside this pane.") }
        progress("Watching \(app.root.path) — save a file to rebuild. Ctrl+C stops.")
        let stop = StopFlag(), restore = stop.catchInterrupts()
        defer { restore() }
        var snapshot = sourceSnapshot(app.root, ignoring: derived)
        while !stop.value {
            try await Task.sleep(nanoseconds: 700_000_000)
            var current = sourceSnapshot(app.root, ignoring: derived)
            guard current != snapshot else { continue }
            // Let an editor finish writing (or a formatter run) before building.
            try await Task.sleep(nanoseconds: 400_000_000)
            current = sourceSnapshot(app.root, ignoring: derived)
            let changed = Set(current.keys).symmetricDifference(snapshot.keys).union(current.keys.filter { snapshot[$0] != nil && snapshot[$0] != current[$0] })
            snapshot = current
            progress("\n↻ \(changed.count == 1 ? URL(fileURLWithPath: changed.first!).lastPathComponent : "\(changed.count) files") changed")
            do { try await buildInstallLaunch(app, phone: saved, derived: derived, product: product, bundle: bundle) }
            catch { progress("✗ \(error.localizedDescription)") }
        }
    }

    func ensureBooted(_ phone: Phone) async throws {
        let state = try (await catalog()).device(for: phone).state
        if state == "Booted" { return }
        guard state == "Shutdown" || state == "Booting" else { throw Failure("Phone is \(state); wait and retry") }
        if state == "Shutdown" { progress("Booting \(phone.name)…"); _ = try await simctl(["boot", phone.udid]) }
        _ = try await simctl(["bootstatus", phone.udid, "-b"], timeout: 240)
    }

    private func xcodeApp(_ args: Arguments) async throws -> XcodeApp {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func absolute(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL }
        let container: [String]
        if let workspace = args.options["workspace"] { container = ["-workspace", absolute(workspace).path] }
        else if let project = args.options["project"] { container = ["-project", absolute(project).path] }
        else {
            let items = (try? FileManager.default.contentsOfDirectory(at: cwd, includingPropertiesForKeys: nil)) ?? []
            let workspaces = items.filter { $0.pathExtension == "xcworkspace" }, projects = items.filter { $0.pathExtension == "xcodeproj" }
            if workspaces.count == 1 { container = ["-workspace", workspaces[0].path] }
            else if projects.count == 1 { container = ["-project", projects[0].path] }
            else if workspaces.count + projects.count == 0 {
                throw Failure("No Xcode project here. Run this in the folder with your .xcodeproj, or pass --project PATH.")
            } else { throw Failure("Several projects here: \((workspaces + projects).map(\.lastPathComponent).joined(separator: ", ")). Pass --workspace or --project.") }
        }
        let root = URL(fileURLWithPath: container[1]).deletingLastPathComponent()
        let scheme: String
        if let explicit = args.options["scheme"] { scheme = explicit }
        else {
            let list = try JSONSerialization.jsonObject(with: try await CommandRunner.checked(xcrun, ["xcodebuild", "-list", "-json"] + container, timeout: 120)) as? [String: Any]
            let schemes = ((list?["workspace"] ?? list?["project"]) as? [String: Any])?["schemes"] as? [String] ?? []
            let base = URL(fileURLWithPath: container[1]).deletingPathExtension().lastPathComponent
            guard let chosen = schemes.count == 1 ? schemes[0] : schemes.first(where: { $0 == base }) else {
                throw Failure(schemes.isEmpty ? "This project has no shared schemes." : "Choose a scheme with --scheme: \(schemes.joined(separator: ", "))")
            }
            scheme = chosen
        }
        return XcodeApp(container: container, scheme: scheme, configuration: args.options["configuration"] ?? "Debug", root: root)
    }

    private func xcodebuildArguments(_ app: XcodeApp, phone: Phone, derived: URL) throws -> [String] {
        let destination: String
        if phone.isDevice {
            guard let udid = phone.hardwareUDID, !udid.isEmpty else { throw Failure("Registration for '\(phone.name)' has no hardware UDID; register it again") }
            destination = "id=\(udid)"
        } else { destination = "id=\(phone.udid)" }
        return ["xcodebuild"] + app.container + ["-scheme", app.scheme, "-configuration", app.configuration, "-destination", destination,
                                                  "-derivedDataPath", derived.path] + (phone.isDevice ? ["-allowProvisioningUpdates"] : [])
    }

    /// The built .app and its bundle identifier, from the scheme's application target.
    private func appProduct(_ app: XcodeApp, phone: Phone, derived: URL) async throws -> (String, URL) {
        let data = try await CommandRunner.checked(xcrun, try xcodebuildArguments(app, phone: phone, derived: derived) + ["-showBuildSettings", "-json"], timeout: 180)
        let targets = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        for target in targets {
            guard let settings = target["buildSettings"] as? [String: String], settings["WRAPPER_EXTENSION"] == "app",
                  let directory = settings["TARGET_BUILD_DIR"], let product = settings["FULL_PRODUCT_NAME"], let bundle = settings["PRODUCT_BUNDLE_IDENTIFIER"] else { continue }
            return (bundle, URL(fileURLWithPath: directory).appendingPathComponent(product))
        }
        throw Failure("Scheme \(app.scheme) doesn't build an iOS app. Pick another with --scheme.")
    }

    private func buildInstallLaunch(_ app: XcodeApp, phone: Phone, derived: URL, product: URL, bundle: String) async throws {
        let started = Date()
        progress("Building \(app.scheme) for \(phone.name)…")
        let result = try await CommandRunner.run(xcrun, try xcodebuildArguments(app, phone: phone, derived: derived) + ["build"], timeout: 1800)
        let log = try store.directory(phone.name).appendingPathComponent("build.log")
        try? (result.output + Data(result.error.utf8)).write(to: log)
        guard result.status == 0 else {
            let text = String(decoding: result.output, as: UTF8.self) + result.error
            var seen = Set<String>()
            let errors = text.split(separator: "\n").map(String.init).filter { $0.contains(" error: ") || $0.hasPrefix("error:") }.filter { seen.insert($0).inserted }.prefix(8)
            throw Failure("Build failed.\n" + (errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n") + "Full log: \(log.path)")
        }
        progress("✓ Built in \(String(format: "%.1f", Date().timeIntervalSince(started))) s. Installing…")
        for (kind, text) in [(PhoneAction.Kind.install, product.path), (.launch, bundle)] {
            let reply = try await PhoneAgentClient.request(cli: self, name: phone.name, request: PhoneAgentRequest(operation: .act, action: PhoneAction(kind: kind, text: text), includeImage: false))
            if let error = reply.error { throw error }
        }
        progress("✓ \(bundle) is running on \(phone.name)")
    }

    /// Modification dates of the files that make up an app. Build output and VCS folders are skipped.
    func sourceSnapshot(_ root: URL, ignoring derived: URL) -> [String: Date] {
        let skip: Set<String> = [".git", ".build", "build", "DerivedData", "Pods", "node_modules", "xcuserdata", ".swiftpm", "terminal-phone-results"]
        let extensions: Set<String> = ["swift", "m", "mm", "h", "c", "cc", "cpp", "metal", "storyboard", "xib", "plist", "strings", "stringsdict", "xcstrings",
                                       "json", "png", "jpg", "pdf", "svg", "entitlements", "pbxproj", "xcconfig", "intentdefinition", "xcdatamodel", "xcdatamodeld"]
        var result: [String: Date] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in walker {
            if skip.contains(url.lastPathComponent) || url.path.hasPrefix(derived.path) { walker.skipDescendants(); continue }
            guard extensions.contains(url.pathExtension.lowercased()),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            result[url.path] = date
            if result.count > 50_000 { break }
        }
        return result
    }

    // MARK: logs

    func logsCommand(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["all"], options: ["app", "level", "split"])
        let name = try named(args.positionals), saved = try store.load(name)
        if let value = args.options["split"] {
            guard let direction = SplitDirection(rawValue: value) else { throw Failure("--split must be right, left, down or up") }
            var forwarded = ["logs", name]
            if args.flags.contains("all") { forwarded.append("--all") }
            for key in ["app", "level"] { if let option = args.options[key] { forwarded += ["--\(key)", option] } }
            try printJSON(try await TerminalSplit.open(name: name, direction: direction, arguments: forwarded)); return
        }
        let level = args.options["level"] ?? "info"
        guard ["default", "info", "debug"].contains(level) else { throw Failure("--level must be default, info or debug") }
        let remembered = (try? String(contentsOf: store.directory(name).appendingPathComponent("last-app"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = args.options["app"] ?? (args.flags.contains("all") ? nil : remembered)
        if let bundle { try PhoneAgentBackends.validateBundle(bundle) }
        if saved.isDevice {
            guard let bundle else { throw Failure("Pass --app BUNDLE_ID: a real iPhone shows one app's output at a time.") }
            guard saved.acceptsInput else { throw AgentError(.inputDisabled, "Showing app output relaunches the app, which needs input. Run terminal-phone connect \(name).") }
            progress("Relaunching \(bundle) on \(saved.displayModel) to attach to its output. Ctrl+C stops.")
        } else {
            try await ensureBooted(saved)
            guard bundle != nil || args.flags.contains("all") else { throw Failure("Pass --app BUNDLE_ID, or --all for every process. terminal-phone run remembers the app it launched.") }
            progress(bundle.map { "Showing \($0) on \(name). Ctrl+C stops." } ?? "Showing every process on \(name). Ctrl+C stops.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrun)
        process.arguments = await logStreamArguments(saved, bundle: bundle, level: level)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); continuation.resume() }
        }
    }

    /// The xcrun arguments that stream a phone's logs: `log stream` on a simulator (filtered to the
    /// app's process and subsystem when there is one), or a console-attached relaunch on a real iPhone.
    func logStreamArguments(_ phone: Phone, bundle: String?, level: String = "info") async -> [String] {
        if phone.isDevice, let bundle {
            // There is no log stream for real iPhones; relaunching the app attached to the console is the closest thing.
            return ["devicectl", "device", "process", "launch", "--console", "--terminate-existing", "--device", phone.udid,
                    "--environment-variables", "{\"OS_ACTIVITY_DT_MODE\": \"enable\"}", bundle]
        }
        var arguments = ["simctl", "spawn", phone.udid, "log", "stream", "--style", "compact", "--level", level]
        if let bundle {
            var predicate = "subsystem == \"\(bundle)\""
            if let info = try? await simctl(["appinfo", phone.udid, bundle]),
               let plist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
               let executable = plist["CFBundleExecutable"] as? String, executable.range(of: "^[A-Za-z0-9 ._-]+$", options: .regularExpression) != nil {
                predicate = "process == \"\(executable)\" OR " + predicate
            }
            arguments += ["--predicate", predicate]
        }
        return arguments
    }
}
