import Foundation
import Darwin
import TerminalMacCore
import TerminalPhoneCore

/// Seconds to one decimal place, printed exactly in JSON.
func tenths(_ seconds: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", seconds)) }

/// Set from a signal handler, read by an async loop.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }

    /// Sets the flag on Ctrl+C (and SIGTERM) until `restore` runs.
    func catchInterrupts() -> () -> Void {
        let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.value = true }
            source.resume(); return source
        }
        return { for (source, number) in zip(sources, [SIGINT, SIGTERM]) { source.cancel(); Darwin.signal(number, SIG_DFL) } }
    }
}

extension PhoneCLI {
    /// Where recordings and screenshots go by default: the Desktop, else the current directory.
    func mediaURL(_ phone: String, _ kind: String, _ ext: String) -> URL {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let folder = FileManager.default.fileExists(atPath: desktop.path) ? desktop : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"; return f.string(from: Date()) }()
        return folder.appendingPathComponent("terminal-phone \(phone) \(kind) \(stamp).\(ext)")
    }

    // MARK: record

    func recordCommand(_ input: [String]) async throws {
        let args = try Arguments(input, flags: Self.mediaFlags, options: Self.mediaOptions.subtracting(["display"]).union(["output", "duration"]))
        let name = try named(args.positionals), saved = try store.load(name)
        if !saved.isDevice { _ = try await phone(name) }
        let style = try mediaStyle(args, phone: name, appStore: false)
        let output = args.options["output"].map(expandedURL) ?? mediaURL(name, "recording", style.plain || style.transparent ? "mov" : "mp4")
        let ext = output.pathExtension.lowercased(), gif = ext == "gif"
        guard gif || ["mov", "mp4", "m4v"].contains(ext) else { throw Failure("--output must end in .mov, .mp4, .m4v or .gif") }
        if style.transparent, ext != "mov" { throw Failure("A transparent background needs a .mov file (HEVC with alpha)") }
        let duration = try args.options["duration"].map { try number($0, fallback: 0, range: 1...3600, name: "duration") }
        // Plain .mov recordings are written directly; everything else goes through the composer.
        let direct = style.plain && ext == "mov"
        let temporary = FileManager.default.temporaryDirectory
        let movie = direct ? output : temporary.appendingPathComponent("terminal-phone-\(UUID().uuidString).mov")
        defer { if !direct { try? FileManager.default.removeItem(at: movie) } }
        let points = style.frame == nil ? nil : try await pointWidth(saved)
        let (seconds, flow) = try await recordMovie(saved, movie: movie, duration: duration, flowNextTo: output)
        var source = movie
        if !style.plain || !(ext == "mov" || gif) {
            let styled = gif ? temporary.appendingPathComponent("terminal-phone-\(UUID().uuidString).mov") : output
            if !style.plain { progress("Composing the video…") }
            _ = try await MediaVideoExport.export(movie, to: styled, style: style, pointWidth: points, recordedSeconds: seconds)
            source = styled
        }
        if gif {
            progress("Making the GIF…")
            defer { if source != movie { try? FileManager.default.removeItem(at: source) } }
            try await PhoneRecording.gif(from: source, to: output)
        }
        guard FileManager.default.fileExists(atPath: output.path) else { throw Failure("The recording was not saved. Was the phone's screen on?") }
        try printJSON(["ok": true, "name": name, "video": output.path, "flow": flow?.path as Any? ?? NSNull(), "seconds": tenths(seconds), "framed": style.frame != nil,
                       "note": flow == nil ? "Nothing was tapped or typed, so there is no flow to replay." : "Replay it with: terminal-phone replay --phone \(name) '\(flow!.path)'"])
    }

    // MARK: test / replay

    func testCommand(_ input: [String]) async throws {
        let args = try Arguments(input, options: ["phone", "timeout", "junit", "results"])
        guard !args.positionals.isEmpty else {
            throw Failure("Usage: terminal-phone test [--phone NAME] [--timeout 10] [--junit report.xml] [--results DIR] FLOW.yaml|DIRECTORY...")
        }
        let name = args.options["phone"] ?? defaultName
        try validateName(name)
        let saved = try store.load(name)
        if saved.isDevice { guard saved.acceptsInput else { throw AgentError(.inputDisabled, "Flows tap and type, so '\(name)' needs input. Run terminal-phone connect \(name).") } }
        else { _ = try await phone(name) }
        let timeout = try number(args.options["timeout"], fallback: 10, range: 1...120, name: "timeout")
        let results = URL(fileURLWithPath: ((args.options["results"] ?? "terminal-phone-results") as NSString).expandingTildeInPath).standardizedFileURL
        var files: [URL] = []
        for path in args.positionals {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { throw Failure("No such flow: \(path)") }
            if directory.boolValue {
                let found = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
                guard !found.isEmpty else { throw Failure("\(path) has no .yaml flows") }
                files += found
            } else { files.append(url) }
        }
        let runner = PhoneFlowRunner(cli: self, phone: name, timeout: timeout, results: results)
        var reports: [PhoneFlowRunner.Report] = []
        for file in files { reports.append(await runner.run(file)) }
        let passed = reports.filter(\.ok).count
        progress(reports.count == 1 ? "" : "\n\(passed) of \(reports.count) flows passed")
        if let junit = args.options["junit"] {
            try PhoneFlowRunner.junit(reports).write(to: URL(fileURLWithPath: (junit as NSString).expandingTildeInPath), atomically: true, encoding: .utf8)
        }
        try printJSON(["ok": passed == reports.count, "phone": name, "passed": passed, "failed": reports.count - passed, "flows": reports.map(\.json)])
        if passed != reports.count { exit(1) }
    }
}

/// Runs flows through the agent session, so each step gets the same targeting and safety as an agent.
@MainActor
struct PhoneFlowRunner {
    struct StepReport { let line: Int; let source: String; let ok: Bool; let seconds: Double; let error: String? }
    struct Report {
        let file: URL; let ok: Bool; let seconds: Double; let steps: [StepReport]; let error: String?; let screenshot: URL?
        var json: [String: Any] {
            ["file": file.path, "ok": ok, "seconds": tenths(seconds), "error": error as Any? ?? NSNull(), "screenshot": screenshot?.path as Any? ?? NSNull(),
             "steps": steps.map { ["line": $0.line, "step": $0.source, "ok": $0.ok, "seconds": tenths($0.seconds), "error": $0.error as Any? ?? NSNull()] }]
        }
    }
    struct StepFailure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    let cli: PhoneCLI, phone: String, timeout: Double, results: URL

    func run(_ file: URL) async -> Report {
        let started = Date()
        let label = file.lastPathComponent
        cli.progress("▶ \(label)  (\(phone))")
        let flow: PhoneFlow
        do { flow = try PhoneFlow.parse(String(contentsOf: file, encoding: .utf8)) }
        catch {
            cli.progress("  ✗ \(error.localizedDescription)")
            return Report(file: file, ok: false, seconds: 0, steps: [], error: error.localizedDescription, screenshot: nil)
        }
        var steps: [StepReport] = []
        for step in flow.steps {
            let begun = Date()
            do {
                try await perform(step, directory: file.deletingLastPathComponent())
                let seconds = Date().timeIntervalSince(begun)
                steps.append(StepReport(line: step.line, source: step.source, ok: true, seconds: seconds, error: nil))
                cli.progress("  ✓ \(String(step.line).leftPad(3))  \(step.source)  \(String(format: "%.1fs", seconds))")
            } catch {
                let seconds = Date().timeIntervalSince(begun), message = error.localizedDescription
                steps.append(StepReport(line: step.line, source: step.source, ok: false, seconds: seconds, error: message))
                cli.progress("  ✗ \(String(step.line).leftPad(3))  \(step.source)  \(String(format: "%.1fs", seconds))\n         \(message)")
                let shot = await failureScreenshot(file, line: step.line)
                if let shot { cli.progress("         Screenshot: \(shot.path)") }
                return Report(file: file, ok: false, seconds: Date().timeIntervalSince(started), steps: steps, error: "line \(step.line): \(message)", screenshot: shot)
            }
        }
        cli.progress("  passed in \(String(format: "%.1fs", Date().timeIntervalSince(started)))")
        return Report(file: file, ok: true, seconds: Date().timeIntervalSince(started), steps: steps, error: nil, screenshot: nil)
    }

    private func request(_ request: PhoneAgentRequest) async throws -> PhoneAgentReply {
        try await PhoneAgentClient.request(cli: cli, name: phone, request: request)
    }
    private func observe(image: Bool = false) async throws -> PhoneObservation {
        let reply = try await request(PhoneAgentRequest(operation: .observe, includeImage: image))
        if let error = reply.error { throw StepFailure(message: error.message) }
        guard let observation = reply.observation else { throw StepFailure(message: "The phone returned no observation") }
        return observation
    }

    private func perform(_ step: PhoneFlowStep, directory: URL) async throws {
        switch step.kind {
        case .act(var action):
            if action.kind == .install, let path = action.text, !path.hasPrefix("/"), !path.hasPrefix("~") {
                action.text = directory.appendingPathComponent(path).standardizedFileURL.path
            }
            try await act(action)
        case .tapText(let text): try await tap(text)
        case .expect(let condition, let wait):
            let reply = try await request(PhoneAgentRequest(operation: .wait, condition: condition, timeout: wait ?? timeout, includeImage: false))
            if let error = reply.error {
                let seconds = Int(wait ?? timeout)
                let subject = condition.text.map { "“\($0)”" } ?? condition.identifier.map { "#\($0)" } ?? condition.app ?? "it"
                throw StepFailure(message: error.code == .waitTimeout ? (condition.absent ? "\(subject) was still on screen after \(seconds) s" : "\(subject) did not appear within \(seconds) s") : error.message)
            }
        case .pause(let seconds): try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        case .screenshot(let path):
            let observation = try await observe(image: true)
            guard let image = observation.screenshot else { throw StepFailure(message: "The phone returned no screenshot") }
            let output = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: image), to: output)
        }
    }

    /// Acts, retrying while the target hasn't appeared yet (screens animate in), until the step timeout.
    private func act(_ action: PhoneAction) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let reply = try await request(PhoneAgentRequest(operation: .act, action: action, includeImage: false))
            guard let error = reply.error else { return }
            if [.targetNotFound, .staleReference].contains(error.code), Date() < deadline {
                try await Task.sleep(nanoseconds: 300_000_000); continue
            }
            throw StepFailure(message: error.message)
        }
    }

    /// Taps the first enabled element, top to bottom, whose label or identifier is `text`;
    /// failing that, one whose label contains it.
    private func tap(_ text: String) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let elements = try await observe().elements.filter(\.element.enabled)
            let match = elements.first { $0.element.label == text } ?? elements.first { $0.element.identifier == text }
                ?? elements.first { $0.element.label?.localizedCaseInsensitiveContains(text) == true }
            if let match {
                let reply = try await request(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .tap, target: ElementSelector(ref: match.ref)), includeImage: false))
                guard let error = reply.error else { return }
                guard error.code == .staleReference, Date() < deadline else { throw StepFailure(message: error.message) }
            } else if Date() >= deadline {
                throw StepFailure(message: "Nothing on screen is labelled “\(text)” after \(Int(timeout)) s")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func failureScreenshot(_ file: URL, line: Int) async -> URL? {
        guard let observation = try? await observe(image: true), let image = observation.screenshot else { return nil }
        let base = file.lastPathComponent.replacingOccurrences(of: ".flow.yaml", with: "").replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: "")
        let output = results.appendingPathComponent("\(base)-line\(line).png")
        do {
            try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: image), to: output)
            return output
        } catch { return nil }
    }

    static func junit(_ reports: [Report]) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let failures = reports.filter { !$0.ok }.count, total = reports.reduce(0) { $0 + $1.seconds }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites tests=\"\(reports.count)\" failures=\"\(failures)\" time=\"\(String(format: "%.2f", total))\">\n"
        xml += "  <testsuite name=\"terminal-phone\" tests=\"\(reports.count)\" failures=\"\(failures)\" time=\"\(String(format: "%.2f", total))\">\n"
        for report in reports {
            xml += "    <testcase name=\"\(escape(report.file.lastPathComponent))\" classname=\"terminal-phone\" time=\"\(String(format: "%.2f", report.seconds))\""
            if let error = report.error { xml += ">\n      <failure message=\"\(escape(error))\">\(escape(error))</failure>\n    </testcase>\n" } else { xml += "/>\n" }
        }
        return xml + "  </testsuite>\n</testsuites>\n"
    }
}

private extension String {
    func leftPad(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
