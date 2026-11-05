import AppKit
import TerminalMacCore
import TerminalPhoneCore

/// Small everyday controls: simulator settings, the clipboard, framed screenshots and the action log.
extension PhoneCLI {
    /// `[NAME] SUBCOMMAND ...`: the phone name is optional when the first word is a subcommand.
    func nameAndSubcommand(_ positionals: [String], _ subcommands: [String], usage: String) throws -> (name: String, subcommand: String, rest: [String]) {
        var positions = positionals
        guard let first = positions.first else { throw Failure(usage) }
        let name = subcommands.contains(first) ? defaultName : positions.removeFirst()
        try validateName(name)
        guard let subcommand = positions.first, subcommands.contains(subcommand) else { throw Failure(usage) }
        return (name, subcommand, Array(positions.dropFirst()))
    }

    // MARK: sim

    static let privacyServices = ["all", "calendar", "contacts-limited", "contacts", "location", "location-always", "photos-add", "photos",
                                  "media-library", "microphone", "motion", "reminders", "siri"]
    static let textSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
                            "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large",
                            "accessibility-extra-extra-extra-large", "increment", "decrement"]

    func simCommand(_ input: [String]) async throws {
        let usage = """
        Usage: terminal-phone sim [NAME] statusbar clean|clear
               terminal-phone sim [NAME] location LATITUDE,LONGITUDE | clear
               terminal-phone sim [NAME] push BUNDLE_ID (PAYLOAD.json | --text 'Hello' [--title 'Title'])
               terminal-phone sim [NAME] permission grant|revoke|reset SERVICE [BUNDLE_ID]
               terminal-phone sim [NAME] text-size [SIZE]
               terminal-phone sim [NAME] appearance [dark|light]
        """
        let args = try Arguments(input, options: ["text", "title"])
        let (name, subcommand, rest) = try nameAndSubcommand(args.positionals, ["statusbar", "location", "push", "permission", "text-size", "appearance"], usage: usage)
        guard args.options.isEmpty || subcommand == "push" else { throw Failure(usage) }
        let saved = try store.load(name)
        if saved.isDevice {
            // A real iPhone only exposes appearance through WebDriverAgent.
            guard subcommand == "appearance", let mode = rest.first, ["dark", "light"].contains(mode), rest.count == 1 else {
                throw Failure(subcommand == "appearance" ? "On a real iPhone, pass dark or light." : "'\(name)' is a real iPhone; sim \(subcommand) works on simulators only.")
            }
            guard saved.acceptsInput else { throw AgentError(.inputDisabled, "Changing a real iPhone's settings needs input. Run terminal-phone connect \(name).") }
            try await PhoneDevices.connect(self, saved, progress: false).appearance(dark: mode == "dark")
            try printJSON(["ok": true, "name": name, "appearance": mode]); return
        }
        _ = try await phone(name)
        let udid = saved.udid
        var result: [String: Any] = ["ok": true, "name": name, "udid": udid]
        switch subcommand {
        case "statusbar":
            guard rest.count == 1, ["clean", "clear"].contains(rest[0]) else { throw Failure(usage) }
            if rest[0] == "clean" {
                _ = try await simctl(["status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
                                      "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "", "--batteryState", "charged", "--batteryLevel", "100"])
            } else { _ = try await simctl(["status_bar", udid, "clear"]) }
            result["statusBar"] = rest[0]
        case "location":
            guard rest.count == 1 else { throw Failure(usage) }
            if rest[0] == "clear" { _ = try await simctl(["location", udid, "clear"]); result["location"] = NSNull() }
            else {
                let parts = rest[0].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 2, let latitude = parts[0], let longitude = parts[1], (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                    throw Failure("Location must be LATITUDE,LONGITUDE, for example 37.3349,-122.0090")
                }
                _ = try await simctl(["location", udid, "set", "\(latitude),\(longitude)"])
                result["location"] = ["latitude": NSDecimalNumber(string: String(latitude)), "longitude": NSDecimalNumber(string: String(longitude))]
            }
        case "push":
            guard let bundle = rest.first else { throw Failure(usage) }
            try PhoneAgentBackends.validateBundle(bundle)
            let payload: URL
            var temporary: URL?
            if let text = args.options["text"] {
                guard rest.count == 1 else { throw Failure("Pass either a payload file or --text, not both") }
                var alert: [String: Any] = ["body": text]
                if let title = args.options["title"] { alert["title"] = title }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-phone-push-\(UUID().uuidString).json")
                try JSONSerialization.data(withJSONObject: ["aps": ["alert": alert, "sound": "default"]]).write(to: file)
                payload = file; temporary = file
            } else {
                guard rest.count == 2, args.options["title"] == nil else { throw Failure(usage) }
                payload = URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath)
                guard (try? JSONSerialization.jsonObject(with: Data(contentsOf: payload))) is [String: Any] else { throw Failure("\(rest[1]) is not a JSON object") }
            }
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            _ = try await simctl(["push", udid, bundle, payload.path])
            result["pushed"] = bundle
        case "permission":
            guard (2...3).contains(rest.count), ["grant", "revoke", "reset"].contains(rest[0]) else { throw Failure(usage) }
            guard Self.privacyServices.contains(rest[1]) else { throw Failure("SERVICE must be one of: \(Self.privacyServices.joined(separator: ", "))") }
            if rest.count == 3 { try PhoneAgentBackends.validateBundle(rest[2]) }
            else if rest[0] != "reset" { throw Failure("grant and revoke need a BUNDLE_ID") }
            _ = try await simctl(["privacy", udid] + rest)
            result["permission"] = ["change": rest[0], "service": rest[1], "bundleId": rest.count == 3 ? rest[2] : NSNull()] as [String: Any]
        case "text-size":
            guard rest.count <= 1 else { throw Failure(usage) }
            if let size = rest.first {
                guard Self.textSizes.contains(size) else { throw Failure("SIZE must be one of: \(Self.textSizes.joined(separator: ", "))") }
                _ = try await simctl(["ui", udid, "content_size", size])
            }
            result["textSize"] = String(decoding: try await simctl(["ui", udid, "content_size"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        default: // appearance
            guard rest.count <= 1, rest.allSatisfy({ ["dark", "light"].contains($0) }) else { throw Failure(usage) }
            if let mode = rest.first { _ = try await simctl(["ui", udid, "appearance", mode]) }
            result["appearance"] = String(decoding: try await simctl(["ui", udid, "appearance"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try printJSON(result)
    }

    // MARK: clipboard

    func clipboardCommand(_ input: [String]) async throws {
        let usage = "Usage: terminal-phone clipboard [NAME] push [TEXT]   (this Mac's clipboard, or TEXT, to the phone)\n       terminal-phone clipboard [NAME] pull          (the phone's clipboard to this Mac)"
        let args = try Arguments(input)
        let (name, subcommand, rest) = try nameAndSubcommand(args.positionals, ["push", "pull"], usage: usage)
        guard subcommand == "push" ? rest.count <= 1 : rest.isEmpty else { throw Failure(usage) }
        let saved = try store.load(name)
        if saved.isDevice {
            guard saved.acceptsInput else { throw AgentError(.inputDisabled, "The iPhone clipboard needs input permission. Run terminal-phone connect \(name).") }
        } else { _ = try await phone(name) }
        if subcommand == "push" {
            guard let text = rest.first ?? NSPasteboard.general.string(forType: .string), !text.isEmpty else { throw Failure("This Mac's clipboard has no text. Pass TEXT instead.") }
            if saved.isDevice {
                try await PhoneDevices.connect(self, saved, progress: false)
                    .call("POST", "/wda/setPasteboard", ["content": Data(text.utf8).base64EncodedString(), "contentType": "plaintext"])
            } else { try await Self.run(xcrun, ["simctl", "pbcopy", saved.udid], input: Data(text.utf8)) }
            try printJSON(["ok": true, "name": name, "pushed": text.count])
        } else {
            let text: String
            if saved.isDevice {
                let value = try await PhoneDevices.connect(self, saved, progress: false).call("POST", "/wda/getPasteboard", ["contentType": "plaintext"])
                text = (value as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            } else { text = String(decoding: try await simctl(["pbpaste", saved.udid]), as: UTF8.self) }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            try printJSON(["ok": true, "name": name, "text": text])
        }
    }

    /// Runs a command with `input` on stdin.
    static func run(_ executable: String, _ arguments: [String], input: Data, timeout: TimeInterval = 20) async throws {
        let process = Process(), stdin = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = stdin; process.standardOutput = FileHandle.nullDevice; process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else { process.terminate(); throw Failure("\(arguments.prefix(2).joined(separator: " ")) timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure("\(arguments.prefix(2).joined(separator: " ")) failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Framed screenshots

    /// `native` is a full-resolution screenshot; the frame is drawn at the same pixel density.
    func framedPNG(_ native: Data, phone: Phone, scale: Double) throws -> (png: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(native as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("The phone returned an invalid screenshot")
        }
        let renderer = PhoneRenderer(writer: TerminalWriter(), transport: .blocks)
        guard let framed = renderer.framed(image, finish: PhoneViewer.savedFrame(for: phone.name, store: store),
                                           width: Int((Double(image.width) / scale).rounded()), height: Int((Double(image.height) / scale).rounded()), pixelsPerPoint: scale),
              let png = NSBitmapImageRep(cgImage: framed).representation(using: .png, properties: [:]) else { throw Failure("Cannot draw the device frame") }
        return (png, framed.width, framed.height)
    }

    // MARK: log

    func logCommand(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["json", "follow"], options: ["tail"])
        let name = try named(args.positionals)
        _ = try store.load(name)
        let tail = try args.options["tail"].map { value -> Int in
            guard let count = Int(value), count > 0 else { throw Failure("--tail must be a positive number") }
            return count
        } ?? 50
        let url = PhoneActionLog.url(in: try store.directory(name))
        let time = DateFormatter(); time.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func emit(_ entries: [PhoneActionLogEntry]) throws {
            for entry in entries {
                if args.flags.contains("json") { FileHandle.standardOutput.write(try PhoneAgentCoding.encoder().encode(entry) + Data([10])) }
                else { print("\(time.string(from: entry.at))  \(entry.source.padding(toLength: 6, withPad: " ", startingAt: 0))  \(PhoneActionLog.describe(entry))") }
            }
            fflush(stdout)
        }
        var entries = PhoneActionLog.read(url)
        if entries.isEmpty && !args.flags.contains("follow") {
            if !args.flags.contains("json") { progress("No actions recorded for \(name) yet. Input from the viewer and from agents is logged here.") }
            return
        }
        try emit(Array(entries.suffix(tail)))
        guard args.flags.contains("follow") else { return }
        var last = entries.last?.at ?? .distantPast
        while true {
            try await Task.sleep(nanoseconds: 500_000_000)
            entries = PhoneActionLog.read(url).filter { $0.at > last }
            if let newest = entries.last?.at { last = newest; try emit(entries) }
        }
    }
}
