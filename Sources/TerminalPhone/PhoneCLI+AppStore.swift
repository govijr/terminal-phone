import CoreGraphics
import Foundation
import TerminalMacCore
import TerminalPhoneCore

/// App Store screenshots and app previews at the sizes App Store Connect accepts,
/// with an optional device frame, background and caption.
extension PhoneCLI {
    static let mediaFlags: Set<String> = ["frame"]
    static let mediaOptions: Set<String> = ["display", "finish", "background", "caption", "caption-color"]

    static let appStoreUsage = """
    Usage: terminal-phone appstore sizes [--json]
           terminal-phone appstore screenshot [NAME] [STYLE] [--output shot.png]
           terminal-phone appstore record [NAME] [STYLE] [--duration 20] [--output preview.mp4]
           terminal-phone appstore export FILE.png|FILE.mov [STYLE] [--points 402] [--output PATH]
    STYLE: [--display auto|6.9|6.5|6.3|6.1|5.5|4.7|ipad-13|ipad-11] [--frame] [--finish orange]
           [--background light|midnight|'#0b1d3a,#3a6df0'|'#ffffff'|photo.jpg] [--caption 'Text'] [--caption-color '#ffffff']
    """

    /// Reads --frame, --finish, --background, --caption and, for App Store output, --display.
    func mediaStyle(_ args: Arguments, phone: String, appStore: Bool) throws -> MediaStyle {
        var style = MediaStyle()
        if appStore {
            let raw = args.options["display"] ?? "auto"
            if raw == "auto" { style.size = .appStore(nil) }
            else {
                guard let display = AppStoreDisplay(named: raw) else { throw Failure("--display must be auto or one of: \(AppStoreDisplay.names)") }
                style.size = .appStore(display)
            }
        } else if args.options["display"] != nil { throw Failure("--display is for terminal-phone appstore") }
        if let finish = args.options["finish"] { style.frame = try Self.frameFinish(finish) }
        else if args.flags.contains("frame") { style.frame = PhoneViewer.savedFrame(for: phone, store: store) }
        if let raw = args.options["background"] {
            guard let background = MediaBackground.parse(raw) else {
                throw Failure("--background must be a colour like '#1e90ff', two colours for a gradient like '#0b1d3a,#3a6df0', an image file, or one of: \(MediaBackground.presetNames)")
            }
            if appStore, background == .transparent { throw Failure("App Store Connect rejects transparent images and videos; pick a colour, or use terminal-phone record --background transparent") }
            style.background = background
        }
        if let caption = args.options["caption"] {
            guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("--caption is empty") }
            style.caption = caption.replacingOccurrences(of: "\\n", with: "\n")
        }
        if let raw = args.options["caption-color"] {
            guard let color = MediaBackground.color(raw) else { throw Failure("--caption-color must be a colour like '#ffffff'") }
            style.captionColor = color
        }
        return style
    }

    func expandedURL(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }

    func appStoreCommand(_ input: [String]) async throws {
        let args = try Arguments(input, flags: Self.mediaFlags.union(["json"]), options: Self.mediaOptions.union(["output", "duration", "points"]))
        guard let subcommand = args.positionals.first else { throw Failure(Self.appStoreUsage) }
        let rest = Array(args.positionals.dropFirst())
        switch subcommand {
        case "sizes": try appStoreSizes(json: args.flags.contains("json"))
        case "screenshot", "shot": try await appStoreScreenshot(args, name: named(rest))
        case "record": try await appStoreRecord(args, name: named(rest))
        case "export":
            guard rest.count == 1 else { throw Failure(Self.appStoreUsage) }
            try await appStoreExport(args, file: expandedURL(rest[0]))
        default: throw Failure(Self.appStoreUsage)
        }
    }

    private func appStoreSizes(json: Bool) throws {
        if json {
            try printJSON(AppStoreDisplay.allCases.map { display -> [String: Any] in
                ["display": display.rawValue, "title": display.title,
                 "screenshots": display.screenshotSizes.map { [$0.description, $0.swapped.description] }.flatMap { $0 },
                 "preview": [display.previewSize.description, display.previewSize.swapped.description]]
            }); return
        }
        print("App Store Connect sizes (portrait; landscape is the same turned). PNG/JPEG, no transparency.")
        print("Previews: 15–30 s, ≤30 fps, H.264 10–12 Mbps, stereo AAC; terminal-phone adds a silent track.\n")
        for display in AppStoreDisplay.allCases {
            print("  --display \(display.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(display.title)")
            print("               screenshots \(display.screenshotSizes.map(\.description).joined(separator: ", "))   preview \(display.previewSize)")
        }
        print("\n--display auto (the default) picks the size matching the phone exactly, so nothing is resampled.")
        print("Tip: terminal-phone sim statusbar clean gives the classic 9:41, full-battery status bar.")
    }

    /// A full-resolution screenshot and its pixels per point.
    func nativeScreenshot(_ name: String) async throws -> (image: CGImage, scale: Double) {
        let saved = try store.load(name)
        if saved.isDevice {
            let agent = try await PhoneDevices.connect(self, saved, progress: false)
            let screen = try await agent.screen()
            return (try MediaComposer.decode(try await agent.screenshot()), screen.scale)
        }
        let (phone, catalog) = try await phone(name)
        let scale = try screenScale(phone, catalog: catalog)
        return (try MediaComposer.decode(try await simctlScreenshot(phone.udid)), scale)
    }

    private func appStoreScreenshot(_ args: Arguments, name: String) async throws {
        guard args.options["duration"] == nil, args.options["points"] == nil else { throw Failure(Self.appStoreUsage) }
        let style = try mediaStyle(args, phone: name, appStore: true)
        let (image, scale) = try await nativeScreenshot(name)
        let (display, size) = try writeScreenshot(image, scale: scale, style: style,
                                                  to: { display in args.options["output"].map(expandedURL) ?? mediaURL(name, "App Store \(display.rawValue)", "png") })
        try printJSON(screenshotReport(name: name, display: display, size: size, style: style, source: PixelSize(image.width, image.height)))
    }

    /// Composes and writes a screenshot; `to` picks the file once the display is known.
    func writeScreenshot(_ image: CGImage, scale: Double, style: MediaStyle, to: (AppStoreDisplay) -> URL) throws -> (AppStoreDisplay, (canvas: PixelSize, url: URL)) {
        let source = PixelSize(image.width, image.height)
        guard case .appStore(let chosen) = style.size else { throw Failure("Expected an App Store size") }
        let display = chosen ?? AppStoreDisplay.auto(for: source)
        let composer = try MediaComposer(style: style, source: source, scale: scale, canvas: display.screenshotSize(for: source))
        let url = to(display)
        guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { throw Failure("--output must end in .png or .jpg") }
        try MediaComposer.write(try composer.image(image), to: url)
        return (display, (composer.layout.canvas, url))
    }

    private func screenshotReport(name: String?, display: AppStoreDisplay, size: (canvas: PixelSize, url: URL), style: MediaStyle, source: PixelSize) -> [String: Any] {
        let bare = !style.decorated && style.caption == nil
        var report: [String: Any] = ["ok": true, "image": size.url.path, "width": size.canvas.width, "height": size.canvas.height,
                                     "display": display.rawValue, "displayTitle": display.title, "framed": style.frame != nil,
                                     "pixelExact": bare && size.canvas == source]
        if bare, size.canvas != source {
            report["note"] = "The screen (\(source)) is not an accepted \(display.rawValue)\" size, so it was scaled and cropped slightly to \(size.canvas). For pixel-exact screenshots use a phone of that size, or add --frame or --background."
        }
        if let name { report["name"] = name }
        return report
    }

    private func appStoreRecord(_ args: Arguments, name: String) async throws {
        guard args.options["points"] == nil else { throw Failure(Self.appStoreUsage) }
        let style = try mediaStyle(args, phone: name, appStore: true)
        let saved = try store.load(name)
        if !saved.isDevice { _ = try await phone(name) }
        let output = args.options["output"].map(expandedURL) ?? mediaURL(name, "app preview", "mp4")
        guard ["mp4", "mov", "m4v"].contains(output.pathExtension.lowercased()) else { throw Failure("--output must end in .mp4, .mov or .m4v") }
        let duration = try args.options["duration"].map { try number($0, fallback: 0, range: 1...3600, name: "duration") }
        let points = try await pointWidth(saved)
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-phone-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: raw) }
        if duration == nil { progress("App Store previews run 15–30 s; anything past 30 s is trimmed.") }
        let (seconds, flow) = try await recordMovie(saved, movie: raw, duration: duration, flowNextTo: output)
        progress("Encoding the app preview…")
        let result = try await MediaVideoExport.export(raw, to: output, style: style, pointWidth: points, recordedSeconds: seconds, maxSeconds: AppPreviewRules.maximumSeconds)
        try printJSON(videoReport(result, output: output, style: style, extra: ["name": name, "recordedSeconds": tenths(seconds), "flow": flow?.path as Any? ?? NSNull()]))
    }

    private func appStoreExport(_ args: Arguments, file: URL) async throws {
        guard args.options["duration"] == nil else { throw Failure(Self.appStoreUsage) }
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure("No such file: \(file.path)") }
        let style = try mediaStyle(args, phone: defaultName, appStore: true)
        let points = try args.options["points"].map { try number($0, fallback: 0, range: 100...2000, name: "points") }
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "tiff"].contains(ext) {
            let image = try MediaComposer.decode(try Data(contentsOf: file))
            let source = PixelSize(image.width, image.height)
            let scale = points.map { Double(min(source.width, source.height)) / $0 } ?? MediaComposer.guessScale(source)
            let (display, size) = try writeScreenshot(image, scale: scale, style: style, to: { display in
                args.options["output"].map(expandedURL) ?? file.deletingLastPathComponent().appendingPathComponent("\(base) App Store \(display.rawValue).png")
            })
            try printJSON(screenshotReport(name: nil, display: display, size: size, style: style, source: source))
        } else if ["mov", "mp4", "m4v"].contains(ext) {
            let output = args.options["output"].map(expandedURL) ?? file.deletingLastPathComponent().appendingPathComponent("\(base) app preview.mp4")
            guard output != file else { throw Failure("--output must differ from the input") }
            guard ["mp4", "mov", "m4v"].contains(output.pathExtension.lowercased()) else { throw Failure("--output must end in .mp4, .mov or .m4v") }
            progress("Encoding the app preview…")
            let result = try await MediaVideoExport.export(file, to: output, style: style, pointWidth: points, maxSeconds: AppPreviewRules.maximumSeconds)
            try printJSON(videoReport(result, output: output, style: style, extra: ["source": file.path]))
        } else { throw Failure("export takes a .png, .jpg, .mov, .mp4 or .m4v file") }
    }

    func videoReport(_ result: MediaVideoExport.Result, output: URL, style: MediaStyle, extra: [String: Any]) -> [String: Any] {
        var report: [String: Any] = ["ok": true, "video": output.path, "width": result.size.width, "height": result.size.height,
                                     "seconds": tenths(result.seconds), "fps": AppPreviewRules.framesPerSecond, "framed": style.frame != nil]
        if case .appStore = style.size { report["appPreview"] = true }
        if !result.warnings.isEmpty { report["warnings"] = result.warnings }
        return report.merging(extra) { $1 }
    }

    /// The screen's short side in points, for sizing the frame around a recording.
    func pointWidth(_ phone: Phone) async throws -> Double? {
        if phone.isDevice {
            let screen = try await PhoneDevices.connect(self, phone, progress: false).screen()
            return Double(min(screen.width, screen.height))
        }
        let screen = try screen(phone, catalog: try await catalog())
        return Double(min(screen.width, screen.height))
    }

    /// Records until Ctrl+C or `duration`, then returns the length and the replayable flow, if any.
    func recordMovie(_ saved: Phone, movie: URL, duration: Double?, flowNextTo base: URL) async throws -> (seconds: Double, flow: URL?) {
        let stop = StopFlag(), restore = stop.catchInterrupts()
        defer { restore() }
        let recording = try await PhoneRecording.start(cli: self, phone: saved, movie: movie)
        progress(duration.map { "Recording \(saved.name) for \(Int($0)) s… (Ctrl+C stops early)" } ?? "Recording \(saved.name)… press Ctrl+C to stop.")
        let deadline = duration.map { Date().addingTimeInterval($0) }
        while !stop.value, deadline.map({ Date() < $0 }) ?? true { try await Task.sleep(nanoseconds: 100_000_000) }
        let seconds = Date().timeIntervalSince(recording.started)
        let flow = recording.stop(flowNextTo: base)
        guard FileManager.default.fileExists(atPath: movie.path) else { throw Failure("The recording was not saved. Was the phone's screen on?") }
        return (seconds, flow)
    }
}
