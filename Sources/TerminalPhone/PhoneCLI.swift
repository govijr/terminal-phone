import AppKit
import TerminalMacCore
import TerminalPhoneCore

@main
struct TerminalPhone {
    @MainActor static func main() async {
        do { try await PhoneCLI().run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            let value: [String: Any]
            if let error = error as? AgentError,
               let object = try? JSONSerialization.jsonObject(with: PhoneAgentCoding.encoder().encode(error)) {
                value = ["ok": false, "schemaVersion": PhoneAgentAPI.version, "error": object]
            } else { value = ["ok": false, "error": error.localizedDescription] }
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
            FileHandle.standardError.write(data + Data([10])); exit(1)
        }
    }
}

/// The simulator display: its framebuffer in pixels and the point space idb uses for input.
struct PhoneScreen {
    let scale: Double
    let nativeWidth: Int
    let nativeHeight: Int
    var width: Int { Int((Double(nativeWidth) / scale).rounded()) }
    var height: Int { Int((Double(nativeHeight) / scale).rounded()) }
}

struct PhoneFrame {
    let png: Data
    let width: Int
    let height: Int
    let nativeWidth: Int
    let nativeHeight: Int
    let scale: Double
}

@MainActor
final class PhoneCLI {
    let store: PhoneStore
    init(store: PhoneStore = PhoneStore()) { self.store = store; PhoneSetup.configureEnvironment() }
    let xcrun = "/usr/bin/xcrun"
    var idb: String? { CommandRunner.executable("idb") }
    var touchAvailable: Bool { idb != nil && CommandRunner.executable("idb_companion") != nil }
    func simctl(_ arguments: [String], timeout: TimeInterval = 60) async throws -> Data {
        try await CommandRunner.checked(xcrun, ["simctl"] + arguments, timeout: timeout)
    }
    func catalog() async throws -> SimulatorCatalog {
        try JSONDecoder().decode(SimulatorCatalog.self, from: await simctl(["list", "--json"]))
    }
    func printJSON(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        FileHandle.standardOutput.write(data + Data([10]))
    }
    func progress(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    func phone(_ name: String, booted: Bool = true) async throws -> (Phone, SimulatorCatalog) {
        let saved = try store.load(name)
        let catalog = try await catalog()
        let device = try catalog.device(for: saved)
        guard !booted || device.state == "Booted" else { throw Failure("Phone '\(name)' is \(device.state). Run terminal-phone up \(name).") }
        return (saved, catalog)
    }
    func named(_ arguments: [String]) throws -> String {
        guard arguments.count <= 1 else { throw Failure("Expected at most one phone name") }
        let name = arguments.first ?? defaultName; try validateName(name)
        guard !["screenshot", "snapshot", "tap", "swipe", "type", "button", "key", "describe"].contains(name) else {
            throw Failure("Phone names cannot be action words such as '\(name)'; choose a name like work or agent-1")
        }
        return name
    }
    func run(_ input: [String]) async throws {
        let command = input.first ?? (isatty(STDIN_FILENO) == 1 ? "up" : "help")
        let tail = Array(input.dropFirst())
        switch command {
        case "help", "--help", "-h": print(Self.help)
        case "version", "--version": print("terminal-phone \(PhoneAgentAPI.productVersion)")
        case "setup": try await setupCommand(tail)
        case "self": try await selfCommand(tail)
        case "connect": try await connectCommand(tail)
        case "observe", "act", "wait", "capabilities", "session", "schema", "mcp": try await agentCommand(command, tail)
        case "_session-host": try await PhoneAgentHost.run(cli: self, name: named(tail))
        case "doctor":
            _ = try Arguments(tail)
            guard tail.isEmpty else { throw Failure("Usage: terminal-phone doctor") }
            let result = try await CommandRunner.run(xcrun, ["simctl", "list", "--json"])
            let found = try? JSONDecoder().decode(SimulatorCatalog.self, from: result.output)
            let runtimes = found?.runtimes.filter { $0.isAvailable && $0.identifier.contains(".iOS-") }.map(\.version) ?? []
            try printJSON(["ok": result.status == 0 && !runtimes.isEmpty,
                           "simulatorAvailable": result.status == 0, "iOSRuntimes": runtimes,
                           "touchAutomationAvailable": touchAvailable,
                           "idb": idb as Any? ?? NSNull(),
                           "idbCompanion": CommandRunner.executable("idb_companion") as Any? ?? NSNull(),
                           "agentAPI": PhoneAgentAPI.version, "mcp": true,
                           "dataDirectory": store.root.path,
                           "setup": "Run terminal-phone setup to configure Xcode, iOS and touch control automatically.",
                           "simulatorError": result.status == 0 ? "" : String(result.error.prefix(2000))])
        case "devices", "runtimes":
            guard tail.isEmpty else { throw Failure("Usage: terminal-phone \(command)") }
            let found = try await catalog()
            if command == "devices" {
                try printJSON(found.devicetypes.filter { $0.productFamily == "iPhone" || $0.name.hasPrefix("iPhone") }.map { ["name": $0.name, "identifier": $0.identifier] })
            } else {
                try printJSON(found.runtimes.filter { $0.identifier.contains(".iOS-") }.map { ["name": $0.name, "version": $0.version, "identifier": $0.identifier, "available": $0.isAvailable] as [String: Any] })
            }
        case "up": try await up(tail)
        case "list", "ls":
            guard tail.isEmpty else { throw Failure("Usage: terminal-phone list") }
            let names = try store.names()
            if names.isEmpty { try printJSON([]); return }
            let found = try await catalog()
            let devices = try? await PhoneDevices.list(self)
            try printJSON(try names.map { name -> [String: Any] in
                let saved = try store.load(name)
                return ["name": name, "udid": saved.udid, "runtime": saved.runtime, "kind": saved.isDevice ? "device" : "simulator",
                        "state": saved.isDevice ? deviceState(saved, devices) : (try? found.device(for: saved).state) ?? "Unavailable"]
            })
        case "status", "stop":
            let name = try named(tail)
            if command == "stop" { _ = try await PhoneAgentClient.stop(cli: self, name: name) }
            if let saved = try? store.load(name), saved.isDevice {
                // A real iPhone is never shut down; stop only ends the WebDriverAgent runner.
                let stopped = command == "stop" ? PhoneDevices.stopRunner(self, saved) : false
                try printJSON(["ok": true, "name": name, "udid": saved.udid, "kind": "device", "model": saved.displayModel, "runtime": saved.runtime,
                               "state": deviceState(saved, try? await PhoneDevices.list(self)), "inputAllowed": saved.acceptsInput,
                               "webDriverAgentStopped": stopped])
                return
            }
            let (saved, found) = try await phone(name, booted: false)
            var state = try found.device(for: saved).state
            if command == "stop", state == "Booted" {
                _ = try await simctl(["shutdown", saved.udid]); state = "Shutdown"
            } else if command == "stop", state != "Shutdown" { throw Failure("Phone is \(state); wait for it to finish transitioning") }
            try printJSON(["ok": true, "name": name, "udid": saved.udid, "state": state, "deviceType": saved.deviceType, "runtime": saved.runtime])
        case "install", "launch", "open":
            let args = try Arguments(tail)
            guard (1...2).contains(args.positionals.count) else { throw Failure("Usage: terminal-phone \(command) [NAME] \(command == "install" ? "/path/to/Simulator.app" : command == "launch" ? "BUNDLE_ID" : "URL")") }
            let name = args.positionals.count == 2 ? args.positionals[0] : defaultName
            let value = args.positionals.last!
            let action = PhoneAction(kind: PhoneAction.Kind(rawValue: command)!, text: value)
            let reply = try await PhoneAgentClient.request(cli: self, name: name, request: PhoneAgentRequest(operation: .act, action: action, includeImage: false))
            if let error = reply.error { throw error }
            try printJSON(["ok": true, "name": name, "udid": reply.session.udid, "result": "\(command) completed"])
        case "action": try await action(tail)
        case "sim": try await simCommand(tail)
        case "clipboard": try await clipboardCommand(tail)
        case "log": try await logCommand(tail)
        case "record": try await recordCommand(tail)
        case "appstore", "app-store": try await appStoreCommand(tail)
        case "test", "replay": try await testCommand(tail)
        case "run": try await runCommand(tail)
        case "logs": try await logsCommand(tail)
        case "device": try await device(tail)
        case "view":
            let args = try Arguments(tail, flags: ["read-only"], options: ["protocol", "cell-size", "split", "frame"])
            let name = try named(args.positionals), saved = try store.load(name)
            try applyFrame(args, to: name)
            if let split = args.options["split"] {
                guard let direction = SplitDirection(rawValue: split) else { throw Failure("--split must be right, left, down or up") }
                try rememberPhone(name)
                try printJSON(try await TerminalSplit.open(name: name, direction: direction, extraArguments: viewerArguments(args)))
                return
            }
            if !saved.isDevice && !args.flags.contains("read-only") { try await PhoneSetup(cli: self).ensureSimulator(allowDownload: true) }
            if isatty(STDIN_FILENO) == 1 { try rememberPhone(name) }
            try await PhoneViewer(cli: self, phone: saved, screen: viewScreen(saved), graphics: args.options["protocol"], readOnly: args.flags.contains("read-only"), cellSize: args.options["cell-size"]).run()
        default: throw Failure("Unknown command: \(command). Run terminal-phone help.")
        }
    }

    func up(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["no-view", "read-only", "allow-input"], options: ["device", "runtime", "protocol", "cell-size", "device-id", "split", "frame"])
        let name = try named(args.positionals)
        let split = try args.options["split"].map { value -> SplitDirection in
            guard let direction = SplitDirection(rawValue: value) else { throw Failure("--split must be right, left, down or up") }
            guard !args.flags.contains("no-view") else { throw Failure("Choose either --split or --no-view") }
            return direction
        }
        let frame = try args.options["frame"].map(Self.frameFinish)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let saved: Phone
        let existing = try? store.load(name)
        if args.options["device-id"] != nil || existing?.isDevice == true {
            try await PhoneSetup(cli: self).ensureXcode()
            if let existing, existing.isDevice { try await prepareRealDevice(existing) }
            saved = try await upDevice(name, existing: existing, query: args.options["device-id"], allowInput: args.flags.contains("allow-input"))
        } else {
            try await PhoneSetup(cli: self).ensureSimulator(allowDownload: true)
            let directory = try store.directory(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lock = try FileLock(directory.appendingPathComponent("setup.lock"))
            defer { withExtendedLifetime(lock) {} }
            let found = try await catalog()
            let registration = try store.directory(name).appendingPathComponent("phone.json")
            if FileManager.default.fileExists(atPath: registration.path) {
                saved = try store.load(name)
                let device = try found.device(for: saved)
                if let wanted = args.options["device"], ![device.deviceTypeIdentifier, found.devicetypes.first(where: { $0.identifier == saved.deviceType })?.name].contains(wanted) {
                    throw Failure("This phone already uses another device type. Choose a new phone name to create another model.")
                }
                if let wanted = args.options["runtime"], !found.runtimes.filter({ $0.identifier == saved.runtime }).contains(where: { [$0.identifier, $0.name, $0.version].contains(wanted) }) {
                    throw Failure("This phone already uses another runtime. Choose a new phone name to create another iOS version.")
                }
            } else {
                let (device, runtime) = try found.select(device: args.options["device"], runtime: args.options["runtime"])
                progress("Creating dedicated \(device.name) simulator (\(runtime.name))…")
                let udid = String(decoding: try await simctl(["create", "terminal-phone · \(name)", device.identifier, runtime.identifier]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                saved = try Phone(name: name, udid: udid, deviceType: device.identifier, runtime: runtime.identifier)
                do { try store.save(saved) }
                catch { throw Failure("Simulator \(udid) was created, but registration failed: \(error.localizedDescription). It was left intact for recovery.") }
            }
            let state = try (await catalog()).device(for: saved).state
            if state == "Shutdown" {
                progress("Booting \(name)…")
                _ = try await simctl(["boot", saved.udid])
            } else if state != "Booted" && state != "Booting" { throw Failure("Phone is \(state); wait and retry") }
            _ = try await simctl(["bootstatus", saved.udid, "-b"], timeout: 240)
        }
        if let frame { PhoneViewer.saveFrame(frame, for: name, store: store) }
        if let split {
            try rememberPhone(name)
            var reply = try await TerminalSplit.open(name: name, direction: split, extraArguments: viewerArguments(args))
            reply["udid"] = saved.udid; reply["kind"] = saved.isDevice ? "device" : "simulator"
            try printJSON(reply)
        } else if !args.flags.contains("no-view"), PhoneViewer.supportsCurrentTerminal {
            try rememberPhone(name)
            try await PhoneViewer(cli: self, phone: saved, screen: viewScreen(saved), graphics: args.options["protocol"], readOnly: args.flags.contains("read-only"), cellSize: args.options["cell-size"]).run()
        } else {
            try printJSON(["ok": true, "name": name, "udid": saved.udid, "kind": saved.isDevice ? "device" : "simulator", "state": saved.isDevice ? "Connected" : "Booted",
                           "touchAutomationAvailable": saved.isDevice ? saved.acceptsInput : touchAvailable,
                           "next": "terminal-phone view \(name) --split right",
                           "note": "Open the phone beside this pane with view --split, or run terminal-phone view \(name) in any terminal."])
        }
    }

    static func frameFinish(_ value: String) throws -> FrameFinish {
        guard let finish = FrameFinish(named: value) else { throw Failure("--frame must be one of: \(FrameFinish.names)") }
        return finish
    }
    /// `--frame COLOUR` is remembered for the phone, so later views and splits use it too.
    func applyFrame(_ args: Arguments, to name: String) throws {
        guard let value = args.options["frame"] else { return }
        PhoneViewer.saveFrame(try Self.frameFinish(value), for: name, store: store)
    }
    /// Viewer options to forward to a viewer started in a new pane.
    func viewerArguments(_ args: Arguments) -> [String] {
        var forwarded: [String] = []
        if args.flags.contains("read-only") { forwarded.append("--read-only") }
        for key in ["protocol", "cell-size"] { if let value = args.options[key] { forwarded += ["--\(key)", value] } }
        return forwarded
    }

    func action(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["framed"], options: ["output", "duration"])
        let verbs: Set<String> = ["screenshot", "snapshot", "tap", "swipe", "type", "button", "key", "describe"]
        var positions = args.positionals
        guard !positions.isEmpty else { throw Failure("Usage: terminal-phone action [NAME] screenshot|snapshot|tap|swipe|type|button|describe") }
        let name = verbs.contains(positions[0]) ? defaultName : positions.removeFirst()
        guard !positions.isEmpty, verbs.contains(positions[0]) else { throw Failure("Missing or unknown action") }
        let verb = positions.removeFirst()
        guard args.options["output"] == nil || ["snapshot", "screenshot"].contains(verb) else { throw Failure("--output is only supported for screenshots") }
        guard args.options["duration"] == nil || verb == "swipe" else { throw Failure("--duration is only supported for swipes") }
        guard !args.flags.contains("framed") || ["snapshot", "screenshot"].contains(verb) else { throw Failure("--framed is only supported for screenshots") }
        if !["screenshot", "snapshot", "describe"].contains(verb) {
            try await legacyAgentAction(name: name, verb: verb, values: positions, duration: args.options["duration"]); return
        }
        if let device = try? store.load(name), device.isDevice {
            try await deviceAction(device, verb: verb, values: positions, output: args.options["output"], framed: args.flags.contains("framed")); return
        }
        let (saved, found) = try await phone(name)
        if ["snapshot", "screenshot"].contains(verb) {
            guard positions.isEmpty else { throw Failure("Usage: action [NAME] screenshot [--output PATH]") }
            let scale = try screenScale(saved, catalog: found)
            let native = try await simctl(["io", saved.udid, "screenshot", "--type=png", "-"], timeout: 15)
            let output = URL(fileURLWithPath: ((args.options["output"] ?? "terminal-phone-\(name).png") as NSString).expandingTildeInPath).standardizedFileURL
            if args.flags.contains("framed") {
                let framed = try framedPNG(native, phone: saved, scale: scale)
                try framed.png.write(to: output, options: .atomic)
                try printJSON(["ok": true, "name": name, "udid": saved.udid, "image": output.path, "framed": true, "width": framed.width, "height": framed.height, "scale": scale])
                return
            }
            let frame = try resized(native, scale: scale)
            try frame.png.write(to: output, options: .atomic)
            try printJSON(["ok": true, "name": name, "udid": saved.udid, "image": output.path, "width": frame.width, "height": frame.height,
                           "coordinateSpace": "display-points", "nativeWidth": frame.nativeWidth, "nativeHeight": frame.nativeHeight, "scale": frame.scale])
        } else {
            let result = try await touch(saved, verb: verb, values: positions, duration: args.options["duration"])
            if verb == "describe" {
                // idb returns a JSON tree. Preserve it as structured data for agents.
                try printJSON(["ok": true, "name": name, "udid": saved.udid, "coordinateSpace": "display-points", "elements": try JSONSerialization.jsonObject(with: result)])
            } else { try printJSON(["ok": true, "name": name, "udid": saved.udid, "action": verb]) }
        }
    }

    func touch(_ phone: Phone, verb: String, values: [String], duration: String? = nil) async throws -> Data {
        let arguments = try PhoneInput.idbArguments(action: verb, values: values, udid: phone.udid, duration: duration)
        guard touchAvailable, let idb else { throw Failure("Touch actions and UI inspection need the phone-control runtime. Run terminal-phone setup. Screenshots and --read-only viewing work without it.") }
        let socket = try await PhoneCompanion.socketFor(phone, store: store)
        // Run idb through its environment's Python: a venv's script shebangs break if the project moves.
        let python = URL(fileURLWithPath: idb).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("python3").path
        let launcher = FileManager.default.isExecutableFile(atPath: python) ? (executable: python, prefix: [idb]) : (executable: idb, prefix: [String]())
        for attempt in 0..<3 {
            do { return try await CommandRunner.checked(launcher.executable, launcher.prefix + ["--companion", socket] + arguments, timeout: 30) }
            catch {
                // idb explicitly marks transient accessibility reads as retryable.
                // Input actions are never replayed: a timed-out tap may already have landed.
                guard verb == "describe", attempt < 2, error.localizedDescription.contains("retry the read") else { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw Failure("Accessibility inspection did not complete")
    }

    private func profile(_ phone: Phone, catalog: SimulatorCatalog) -> NSDictionary? {
        guard let path = catalog.devicetypes.first(where: { $0.identifier == phone.deviceType })?.bundlePath else { return nil }
        return NSDictionary(contentsOfFile: path + "/Contents/Resources/profile.plist")
    }
    func screenScale(_ phone: Phone, catalog: SimulatorCatalog) throws -> Double {
        guard let number = profile(phone, catalog: catalog)?["mainScreenScale"] as? NSNumber, (1...4).contains(number.doubleValue) else {
            throw Failure("Cannot determine this simulator's display scale; refusing to guess input coordinates")
        }
        return number.doubleValue
    }
    func screen(_ phone: Phone, catalog: SimulatorCatalog) throws -> PhoneScreen {
        let scale = try screenScale(phone, catalog: catalog), profile = profile(phone, catalog: catalog)
        guard let width = (profile?["mainScreenWidth"] as? NSNumber)?.intValue, let height = (profile?["mainScreenHeight"] as? NSNumber)?.intValue,
              (1...16384).contains(width), (1...16384).contains(height) else {
            throw Failure("Cannot determine this simulator's display size; refusing to guess input coordinates")
        }
        return PhoneScreen(scale: scale, nativeWidth: width, nativeHeight: height)
    }

    func capture(_ phone: Phone, scale: Double) async throws -> PhoneFrame {
        try resized(try await simctl(["io", phone.udid, "screenshot", "--type=png", "-"], timeout: 15), scale: scale)
    }
    /// Resizes a native screenshot to display points, the coordinate space input uses.
    func resized(_ native: Data, scale: Double) throws -> PhoneFrame {
        guard let rep = NSBitmapImageRep(data: native), let source = rep.cgImage else { throw Failure("Simulator returned an invalid screenshot") }
        let width = Int((Double(source.width) / scale).rounded()), height = Int((Double(source.height) / scale).rounded())
        guard (1...8192).contains(width), (1...8192).contains(height),
              let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: image) else { throw Failure("Cannot resize simulator screenshot") }
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let png = image.representation(using: .png, properties: [:]) else { throw Failure("Cannot encode simulator screenshot") }
        return PhoneFrame(png: png, width: width, height: height, nativeWidth: source.width, nativeHeight: source.height, scale: scale)
    }

    static let help = """
    terminal-phone — an interactive iPhone for you and your agents (\(PhoneAgentAPI.productVersion))

      terminal-phone                    set up automatically and open your phone
      terminal-phone setup              install/check the private control runtime
      terminal-phone self install       install the command for every terminal
      terminal-phone connect            guided real-iPhone pairing/signing setup

      terminal-phone up [NAME] [--device 'iPhone 17 Pro'] [--runtime 26.1] [--no-view]
      terminal-phone doctor | devices | runtimes | list
      terminal-phone status|stop [NAME]
      terminal-phone view [NAME] [--split right|left|down|up] [--read-only] [--protocol kitty|iterm|blocks]
      terminal-phone up [NAME] --split right   boot, then open the phone in a pane beside this one
      terminal-phone view [NAME] --frame orange   frame colour, remembered per phone (Ctrl+F picks):
          graphite, black, silver, white, gold, orange, red, pink, yellow, green, blue, purple
      terminal-phone install [NAME] /path/to/simulator-built.app
      terminal-phone launch [NAME] com.example.app
      terminal-phone open [NAME] 'myapp://route'
      terminal-phone action [NAME] screenshot [--output /tmp/phone.png]
      terminal-phone action [NAME] tap X Y
      terminal-phone action [NAME] swipe X1 Y1 X2 Y2 [--duration 0.3]
      terminal-phone action [NAME] type -- 'Hello'
      terminal-phone action [NAME] button HOME|LOCK|SIRI
      terminal-phone action [NAME] key return|backspace|tab|escape|up|down|left|right
      terminal-phone action [NAME] describe
      terminal-phone action [NAME] screenshot --framed   inside the device frame, transparent corners

    Develop and test:
      terminal-phone run [NAME] [--scheme S] [--watch] [--split right]   build this folder's Xcode app, install, launch
      terminal-phone logs [NAME] [--app BUNDLE_ID | --all] [--split right]   stream the app's logs
      terminal-phone record [NAME] [--output demo.mov|demo.mp4|demo.gif] [--duration 30]   video + a replayable flow
          [--frame] [--finish orange] [--background midnight|'#0b1d3a,#3a6df0'|photo.jpg] [--caption 'Text']
      terminal-phone test [--phone NAME] [--junit report.xml] flows/     run flow files; exit 1 on failure
      terminal-phone replay [--phone NAME] demo.flow.yaml                run a recorded flow again
      terminal-phone log [NAME] [--tail 50] [--follow] [--json]          every tap and keystroke, by you or an agent
      In the viewer, Ctrl+R records too (simulators and real iPhones).
      In the viewer, Ctrl+A opens the App Store panel: screenshots and previews without commands.

    App Store screenshots and previews (exact App Store Connect sizes, no transparency):
      terminal-phone appstore sizes                                  every display size it accepts
      terminal-phone appstore screenshot [NAME] [--display auto|6.9|6.3|ipad-13|...] [--output shot.png]
      terminal-phone appstore record [NAME] [--duration 20] [--output preview.mp4]   886x1920, 30 fps, silent AAC
      terminal-phone appstore export FILE.png|FILE.mov               convert an existing screenshot or recording
          style: [--frame] [--finish orange] [--background light|midnight|'#ffffff'|photo.jpg] [--caption 'Track every habit']

    Simulator controls:
      terminal-phone sim [NAME] statusbar clean|clear      9:41, full battery, full signal
      terminal-phone sim [NAME] location 37.3349,-122.0090 | clear
      terminal-phone sim [NAME] push BUNDLE_ID payload.json | --text 'Hello' [--title 'Hi']
      terminal-phone sim [NAME] permission grant|revoke|reset photos|camera|location|... [BUNDLE_ID]
      terminal-phone sim [NAME] text-size [extra-large|accessibility-large|...]
      terminal-phone sim [NAME] appearance [dark|light]    also works on real iPhones
      terminal-phone clipboard [NAME] push [TEXT] | pull   share the clipboard with the phone

    Agent API (JSON; one shared session per phone):
      terminal-phone observe [NAME] [--no-image]
      terminal-phone act [NAME] tap --ref OBSERVATION:e1 --observe
      terminal-phone act [NAME] fill --id message --text 'Hello' --observe
      terminal-phone act [NAME] scroll down [--id LIST] --observe
      terminal-phone act [NAME] press return
      terminal-phone act [NAME] tap --id submit --wait-text 'Welcome' --timeout 10
      terminal-phone wait [NAME] --text 'Welcome' [--absent] [--timeout 10]
      terminal-phone capabilities [NAME]
      terminal-phone session start|status|release|stop [NAME]
      terminal-phone schema | mcp

    Real iPhones (via WebDriverAgent; view-only unless --allow-input):
      terminal-phone device list
      terminal-phone device setup [NAME] --team TEAM_ID [--bundle-prefix com.example.terminalphone]
      terminal-phone device doctor NAME [--check]
      terminal-phone up NAME --device-id 'My iPhone' [--allow-input]
      terminal-phone device revoke NAME  withdraw input; the iPhone becomes view-only
      terminal-phone connect [NAME] --view-only   reconnect and withdraw input
      terminal-phone stop NAME          ends WebDriverAgent; the iPhone keeps running

    NAME uses the last selected phone (initially 'default'). Coordinates use display points.
    'snapshot' aliases screenshot; 'describe' returns the accessibility tree.
    Requires Xcode + an iOS runtime. Touch/UI inspection: terminal-phone setup
    Works in every terminal: sharp images in Ghostty, kitty, iTerm2, WezTerm, Warp and VS Code
    (with images enabled), text graphics elsewhere, and inside tmux. Ctrl+] exits the viewer.
    Data: ~/Library/Application Support/terminal-phone (or TERMINAL_PHONE_HOME).
    Dedicated simulators run on this Mac; they are not macOS VMs or real iPhones.
    """
}
