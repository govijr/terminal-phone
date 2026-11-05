import AppKit
import TerminalMacCore
import TerminalPhoneCore

/// Real-iPhone commands. They mirror the simulator ones: same verbs, same JSON, display points.
extension PhoneCLI {
    func deviceState(_ phone: Phone, _ devices: [ConnectedDevice]?) -> String {
        guard let devices else { return "Unknown" }
        guard let device = devices.first(where: { $0.identifier.caseInsensitiveCompare(phone.udid) == .orderedSame }) else { return "Unpaired" }
        return device.reachable ? "Connected" : "Offline"
    }

    /// The screen geometry the viewer needs, starting WebDriverAgent for a real iPhone.
    func viewScreen(_ phone: Phone) async throws -> PhoneScreen {
        if phone.isDevice { return try await PhoneDevices.connect(self, phone).screen() }
        let (saved, found) = try await self.phone(phone.name)
        return try screen(saved, catalog: found)
    }

    func device(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["check"], options: ["team", "bundle-prefix"])
        switch args.positionals.first {
        case "list", "ls", nil:
            guard args.positionals.count <= 1, args.flags.isEmpty, args.options.isEmpty else { throw Failure("Usage: terminal-phone device list") }
            let names = (try? store.names()) ?? []
            let registered = Dictionary(names.compactMap { name in (try? store.load(name)).flatMap { $0.isDevice ? ($0.udid.uppercased(), name) : nil } }, uniquingKeysWith: { a, _ in a })
            try printJSON(try await PhoneDevices.list(self).map { d -> [String: Any] in
                ["name": d.name, "identifier": d.identifier, "udid": d.hardwareUDID, "model": d.marketingName, "iOS": d.osVersion,
                 "connection": d.transport, "connected": d.reachable, "developerMode": d.developerMode, "pairing": d.pairing,
                 "registeredAs": registered[d.identifier.uppercased()] as Any? ?? NSNull()]
            })
        case "doctor":
            guard args.positionals.count == 2, args.options.isEmpty else { throw AgentError(.invalidRequest, "Usage: terminal-phone device doctor NAME [--check]") }
            let name = args.positionals[1], phone = try store.load(name)
            guard phone.isDevice else { throw AgentError(.invalidRequest, "This registration is a simulator. Use terminal-phone doctor.") }
            let device = try await PhoneDevices.find(self, phone)
            var steps: [String] = []
            if device.pairing != "paired" { steps.append("Pair and trust this iPhone in Xcode → Window → Devices and Simulators.") }
            if device.developerMode != "enabled" { steps.append("Enable Settings → Privacy & Security → Developer Mode on the iPhone.") }
            if !device.reachable { steps.append("Unlock and connect the iPhone by USB or the paired Wi-Fi connection.") }
            if PhoneDevices.xctestrun() == nil { steps.append("Run terminal-phone device setup \(name) --team YOUR_TEAM_ID to build and sign WebDriverAgent.") }
            var report: [String: Any] = ["ok": steps.isEmpty, "name": name, "paired": device.pairing == "paired",
                                         "developerMode": device.developerMode, "connected": device.reachable,
                                         "runnerBuilt": PhoneDevices.xctestrun() != nil, "inputAllowed": phone.acceptsInput,
                                         "nextSteps": steps, "note": "Readiness checks do not prove signing validity. Use --check to test a real observation."]
            if args.flags.contains("check") {
                let reply = try await PhoneAgentClient.request(cli: self, name: name, request: PhoneAgentRequest(operation: .observe, includeImage: false))
                report["ok"] = reply.ok; report["observationChecked"] = reply.ok
                if let error = reply.error { report["error"] = try JSONSerialization.jsonObject(with: PhoneAgentCoding.encoder().encode(error)) }
            }
            try printJSON(report)
            if report["ok"] as? Bool != true { exit(1) }
        case "revoke":
            guard args.positionals.count == 2, args.flags.isEmpty, args.options.isEmpty else { throw AgentError(.invalidRequest, "Usage: terminal-phone device revoke NAME") }
            let phone = try store.load(args.positionals[1])
            guard phone.isDevice else { throw AgentError(.invalidRequest, "'\(phone.name)' is a simulator; simulators have no owner grant to revoke.") }
            let wasAllowed = phone.acceptsInput
            try store.save(phone.withInputAllowed(false))
            // Every session request re-reads the grant, so running sessions become view-only immediately.
            try printJSON(["ok": true, "name": phone.name, "inputAllowed": false, "wasAllowed": wasAllowed,
                           "note": "WebDriverAgent may still be running for viewing. Run terminal-phone stop \(phone.name) to end it."])
        case "setup":
            guard args.positionals.count <= 2, args.flags.isEmpty else { throw Failure("Usage: terminal-phone device setup [NAME] --team TEAM_ID") }
            guard let team = args.options["team"] else { throw Failure("Pass your Apple Developer team ID: terminal-phone device setup --team ABCDE12345 (see Xcode → Settings → Accounts)") }
            let phone = try args.positionals.dropFirst().first.map { try store.load($0) }
            if let phone, !phone.isDevice { throw Failure("'\(phone.name)' is a simulator; simulators don't need WebDriverAgent") }
            if let phone { _ = try await PhoneAgentClient.stop(cli: self, name: phone.name) }
            let prefix = args.options["bundle-prefix"] ?? "com.terminalphone.\(team.lowercased())"
            try printJSON(try await PhoneDevices.setup(self, phone: phone, team: team, bundlePrefix: prefix))
        default: throw Failure("Usage: terminal-phone device list | device setup [NAME] --team TEAM_ID | device doctor NAME | device revoke NAME")
        }
    }

    /// Registers a real iPhone under `name`, or reuses an existing registration.
    func upDevice(_ name: String, existing: Phone?, query: String?, allowInput: Bool) async throws -> Phone {
        let devices = try await PhoneDevices.list(self)
        if let existing {
            if let query, !(devices.first(where: { $0.identifier == existing.udid })?.matches(query) ?? false) {
                throw Failure("'\(name)' is already registered to another device. Choose a new name.")
            }
            guard existing.isDevice else { throw Failure("'\(name)' is a simulator. Choose another name for the iPhone.") }
            if allowInput && existing.allowInput != true {
                // Upgrading to input is an explicit, recorded decision.
                guard let device = devices.first(where: { $0.identifier == existing.udid }) else { throw Failure("The iPhone for '\(name)' isn't paired") }
                let updated = try Phone(name: name, device: device, allowInput: true)
                try store.save(updated); progress("Input enabled for \(name).")
                _ = try await PhoneDevices.connect(self, updated)
                return updated
            }
            _ = try await PhoneDevices.connect(self, existing)
            return existing
        }
        guard let query else { throw Failure("Pass --device-id with a name, identifier or UDID from: terminal-phone device list") }
        let matches = devices.filter { $0.matches(query) }
        guard matches.count == 1, let device = matches.first else {
            throw Failure(matches.isEmpty ? "No paired iPhone matches '\(query)'. Run terminal-phone device list." : "'\(query)' matches several iPhones; use its identifier")
        }
        if let taken = try store.names().first(where: { (try? store.load($0))?.udid.caseInsensitiveCompare(device.identifier) == .orderedSame }) {
            throw Failure("\(device.name) is already registered as '\(taken)'")
        }
        let phone = try Phone(name: name, device: device, allowInput: allowInput)
        try FileManager.default.createDirectory(at: store.directory(name), withIntermediateDirectories: true)
        try store.save(phone)
        progress("Registered \(device.name) as '\(name)'\(allowInput ? " with input allowed" : " (view-only; add --allow-input to let agents tap and type)").")
        try await prepareRealDevice(phone)
        _ = try await PhoneDevices.connect(self, phone)
        return phone
    }

    /// Legacy read commands retain their output shape. All mutations use PhoneAgentSession.
    func deviceAction(_ phone: Phone, verb: String, values: [String], output: String?, framed: Bool = false) async throws {
        let agent = try await PhoneDevices.connect(self, phone)
        var result: [String: Any] = ["ok": true, "name": phone.name, "udid": phone.udid, "kind": "device"]
        switch verb {
        case "screenshot", "snapshot":
            guard values.isEmpty else { throw Failure("Usage: action [NAME] screenshot [--output PATH]") }
            let screen = try await agent.screen()
            let native = try await agent.screenshot()
            let url = URL(fileURLWithPath: ((output ?? "terminal-phone-\(phone.name).png") as NSString).expandingTildeInPath).standardizedFileURL
            if framed {
                let image = try framedPNG(native, phone: phone, scale: screen.scale)
                try image.png.write(to: url, options: .atomic)
                result.merge(["image": url.path, "framed": true, "width": image.width, "height": image.height, "scale": screen.scale]) { $1 }
                break
            }
            let frame = try resized(native, scale: screen.scale)
            try frame.png.write(to: url, options: .atomic)
            result.merge(["image": url.path, "width": frame.width, "height": frame.height, "coordinateSpace": "display-points",
                          "nativeWidth": frame.nativeWidth, "nativeHeight": frame.nativeHeight, "scale": frame.scale]) { $1 }
        case "describe":
            guard values.isEmpty else { throw Failure("Usage: action [NAME] describe") }
            result["coordinateSpace"] = "display-points"; result["elements"] = try await agent.describe()
        default: throw Failure("Unknown action: \(verb)")
        }
        try printJSON(result)
    }
}
