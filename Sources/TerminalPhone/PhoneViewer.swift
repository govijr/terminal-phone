import AppKit
import Darwin
import TerminalMacCore
import TerminalPhoneCore

@MainActor
final class PhoneViewer {
    /// Every interactive terminal works: inline images where the terminal has them, text blocks elsewhere.
    static var supportsCurrentTerminal: Bool { isatty(0) == 1 && isatty(1) == 1 }
    private enum Link: Equatable { case connecting(String), live, polling, waiting(String) }
    private enum Action: Equatable { case menu, select(String), zoomOut, zoomFit, zoomActual, zoomIn, home, lock, screenshot, record, appearance, control, frames, pickFrame(FrameFinish), tools, tool(Tool), logs, appStore, studio(StudioItem) }
    private struct Hit { let row: Int; let columns: ClosedRange<Int>; let action: Action }
    private struct Layout: Equatable {
        let viewport: PhoneViewport
        let columns: Int, rows: Int
        /// Roomy panes get a two-line header, a divider and a pill toolbar; small ones one line each.
        let roomy: Bool
        /// The logs panel, beside the phone in wide panes and below it in narrow ones.
        var logPanel: CellRect? = nil
    }
    private struct Activity { let at: Date; let text: String; let ok: Bool; let milliseconds: Double? }
    private struct MenuItem { let name: String; let detail: String; let state: String }

    let cli: PhoneCLI
    /// `--protocol`, when given. Otherwise the terminal is detected and probed.
    private let requestedGraphics: GraphicsMode?
    private var profile = TerminalProfile.detect(ProcessInfo.processInfo.environment)
    private var graphics: GraphicsMode { switch renderer.currentTransport { case .kittySharedMemory, .kittyDirect: .kitty; case .iterm: .iterm; case .blocks: .blocks } }
    /// Images that are cell content rather than a layer: stale cells must be erased by hand.
    private var imagesAreText: Bool { graphics != .kitty || renderer.currentTarget.placeholders }
    private var viewOnly: Bool
    /// Input needs idb for simulators, and an explicit opt-in for real iPhones.
    private var readOnly: Bool { viewOnly || !phone.acceptsInput || (!phone.isDevice && !cli.touchAvailable) }
    private var inputController: PhoneViewerInput?
    let cellOverride: (Double, Double)?
    private var phone: Phone, screen: PhoneScreen
    private let writer = TerminalWriter()
    private let renderer: PhoneRenderer
    private var live: PhoneLink?, polling: Task<Void, Never>?, switching: Task<Void, Never>?
    private var streamScale = 0.0, pendingScale: (value: Double, since: Date)?
    private var failure: String?
    private var quit = false, liveReady = false, link = Link.connecting("Starting video stream")
    /// A real iPhone that WebDriverAgent reports as locked: iOS ignores input until it's unlocked.
    private var phoneLocked = false
    private var layout: Layout?, size = winsize()
    private var zoom = 1.0, pan = (x: 0.5, y: 0.5)
    private var metrics = PhoneMetricFilter()
    private var queue: [[String: Any]] = []
    private var nextID = 0, inFlight: (id: Int, label: String)?
    private var anchor: (x: Int, y: Int, at: Date)?, pressedChrome = false
    private var wheelSteps = 0, wheelPoint = (0, 0)
    private var wheelAt = Date.distantPast
    private var activity: [Activity] = []
    private var previousChrome = "", firstFrameShown = false
    private var fps = 0.0, fpsSample = (frames: 0, at: Date())
    private var hits: [Hit] = [], flash: (action: Action, at: Date)?
    private var menu: [MenuItem]?, menuIndex = 0, menuArea: (column: Int, row: Int, width: Int, height: Int)?
    private var recording: PhoneRecording?, startingRecording = false
    private var dark: Bool?
    /// The phone's frame colour, saved per phone. Ctrl+F opens the picker.
    private var finish: FrameFinish
    /// The open frame picker: the finish to restore on Esc, and the highlighted row.
    private var picker: (original: FrameFinish, index: Int)?
    /// The open Tools panel's highlighted row, and what it last learned about the phone.
    private var tools: Int?, toolBusy = false
    private var statusBarClean: Bool?, textSize: String?, locationIndex: Int?
    /// The logs panel's stream and what it shows.
    private var logTail: PhoneLogTail?, logTitle = ""
    /// The open App Store panel's highlighted row, its settings, and the caption being typed.
    private var studio: Int?, studioSettings: AppStoreSettings, captionDraft: String?
    /// Set while an App Store preview records: how to compose it when it stops.
    /// How the running recording is saved: an App Store preview in the panel's style, or a plain
    /// recording, which becomes a framed, transparent clip of what was visible if you zoomed in.
    /// `crops` follows the viewer's zoom and pan through the recording.
    private struct RecordingPlan { let appStore: Bool; let style: MediaStyle?; let points: Double; var crops: [(time: Double, crop: MediaRect?)] }
    private var recordingPlan: RecordingPlan?
    private var mediaTask: Task<Void, Never>?, lastMedia: URL?

    init(cli: PhoneCLI, phone: Phone, screen: PhoneScreen, graphics: String?, readOnly: Bool, cellSize: String? = nil) throws {
        self.cli = cli; self.phone = phone; self.screen = screen; self.viewOnly = readOnly
        finish = Self.savedFrame(for: phone.name, store: cli.store)
        studioSettings = (try? PhoneConfiguration.load(store: cli.store))?.appStore ?? AppStoreSettings()
        let e = ProcessInfo.processInfo.environment
        if let graphics, GraphicsMode(rawValue: graphics) == nil { throw Failure("--protocol must be kitty, iterm or blocks") }
        requestedGraphics = graphics.flatMap(GraphicsMode.init(rawValue:))
        guard isatty(0) == 1, isatty(1) == 1 else {
            throw Failure("view needs an interactive terminal. To open the phone beside an agent or another pane, use: terminal-phone view \(phone.name) --split right")
        }
        if let value = cellSize ?? e["TERMINAL_PHONE_CELL_SIZE"] {
            let p = value.lowercased().split(separator: "x").compactMap { Double($0) }
            guard p.count == 2, p.allSatisfy({ $0.isFinite && (1...256).contains($0) }) else { throw Failure("--cell-size must be WIDTHxHEIGHT in terminal pixels, for example 9x24") }
            cellOverride = (p[0], p[1])
        } else { cellOverride = nil }
        // Nothing is drawn until the terminal has been probed; this is only the starting point.
        renderer = PhoneRenderer(writer: writer, transport: .blocks)
    }

    /// Detects the terminal, and inside tmux lets image escapes pass through to it.
    private func prepareTerminal() async {
        let env = ProcessInfo.processInfo.environment
        var tmuxClient: String?, passthrough = false
        if env["TMUX"] != nil, let tmux = TerminalSplit.find("tmux") {
            tmuxClient = (try? await CommandRunner.checked(tmux, ["display-message", "-p", "#{client_termname}"], timeout: 5))
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            // Pane-scoped, so it ends with this pane. tmux before 3.3 has no passthrough option.
            var arguments = ["set-option", "-p"]
            if let pane = env["TMUX_PANE"] { arguments += ["-t", pane] }
            passthrough = ((try? await CommandRunner.run(tmux, arguments + ["allow-passthrough", "on"], timeout: 5))?.status ?? 1) == 0
        }
        profile = TerminalProfile.detect(env, tmuxClientTerm: tmuxClient)
        if profile.tmux && !passthrough && requestedGraphics != .blocks { profile.graphics = .blocks; profile.needsGraphicsProbe = false }
        Theme.depth = profile.colors
        Theme.glyphs = profile.richGlyphs ? .rich : .plain
        if let requestedGraphics { profile.graphics = requestedGraphics; profile.needsGraphicsProbe = requestedGraphics == .kitty }
    }

    /// The probes to send, and how to read their replies. DA1 goes last: terminals answer in
    /// order, so its reply means every earlier query has been answered or ignored.
    private func graphicsProbe() -> (query: String, cleanup: () -> Void)? {
        guard profile.needsGraphicsProbe else { return nil }
        let wrap: (String) -> String = profile.tmux ? TerminalProfile.tmuxPassthrough : { $0 }
        var query = "", cleanup: () -> Void = {}
        if profile.graphics == .kitty || profile.app == .unknown {
            if let shm = PhoneRenderer.sharedMemoryProbe() { query += wrap(shm.query); cleanup = shm.cleanup }
            query += wrap("\u{1b}_Gi=32,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\")
        }
        return (query + "\u{1b}[c", cleanup)
    }

    /// Picks the transport from the probe replies (or their absence).
    private func decideGraphics() -> (GraphicsTransport, RenderTarget) {
        var target = RenderTarget(tmux: profile.tmux, placeholders: false, depth: profile.colors)
        let shm = metrics.graphicsReplies[31] == "OK", direct = metrics.graphicsReplies[32] == "OK"
        let mode: GraphicsMode
        switch profile.graphics {
        case .kitty where !profile.needsGraphicsProbe: mode = .kitty
        // Replies don't always make it back through tmux, so trust the terminal it named.
        case .kitty: mode = shm || direct || profile.tmux ? .kitty : .blocks
        case .iterm where profile.app == .vscode:
            mode = metrics.primaryAttributes?.contains(4) == true ? .iterm : .blocks
            if mode == .blocks { record("Text graphics. For a sharp phone, turn on terminal.integrated.enableImages", ok: true) }
        case .iterm: mode = .iterm
        case .blocks: mode = shm || direct ? .kitty : .blocks
        }
        if mode == .blocks, requestedGraphics == nil, profile.app != .vscode {
            record("Text graphics in \(profile.displayName). Ghostty, kitty, iTerm2 or WezTerm show the phone sharper", ok: true)
        }
        let transport: GraphicsTransport
        switch mode {
        case .kitty:
            transport = shm ? .kittySharedMemory : .kittyDirect
            target.placeholders = profile.tmux
        case .iterm: transport = .iterm
        case .blocks: transport = .blocks
        }
        return (transport, target)
    }

    func run() async throws {
        await prepareTerminal()
        configureInput()
        defer { inputController?.stop() }
        var original = termios()
        guard tcgetattr(0, &original) == 0 else { throw Failure("Cannot read terminal settings") }
        var raw = original; cfmakeraw(&raw)
        guard tcsetattr(0, TCSAFLUSH, &raw) == 0 else { throw Failure("Cannot enter terminal input mode") }
        let signals = [SIGINT, SIGTERM, SIGHUP]
        let oldHandlers = signals.map { Darwin.signal($0, SIG_IGN) }
        let sources = signals.map { number -> DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: number, queue: .main)
            s.setEventHandler { [weak self] in self?.quit = true }; s.resume(); return s
        }
        // Mouse reporting is always on: the toolbar is clickable even in read-only mode.
        writer.write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J\u{1b}[?1002h\u{1b}[?1006h\u{1b}]11;?\u{7}")
        queryMetrics()
        var probe = graphicsProbe()
        if let probe { writer.write(probe.query) }
        defer {
            renderer.configure(placement: nil)
            live?.stop(); polling?.cancel(); switching?.cancel(); logTail?.stop()
            stopRecording(wait: true)
            probe?.cleanup()
            writer.write(renderer.clear() + "\u{1b}[0m\u{1b}[2J\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?25h\u{1b}[?1049l")
            writer.flush()
            tcsetattr(0, TCSAFLUSH, &original)
            for (i, s) in sources.enumerated() { s.cancel(); Darwin.signal(signals[i], oldHandlers[i]) }
        }
        refreshAppearance()
        var parser = TerminalInput(), lastInput = Date(), previousSize = "", lastChrome = Date.distantPast
        let started = Date()
        while !quit {
            _ = ioctl(1, TIOCGWINSZ, &size)
            let key = "\(size.ws_col):\(size.ws_row):\(size.ws_xpixel):\(size.ws_ypixel)"
            if key != previousSize { previousSize = key; queryMetrics(); relayout(clear: true) }
            var fd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            if poll(&fd, 1, 0) > 0 {
                if fd.revents & Int16(POLLHUP | POLLERR) != 0 { break }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(0, &bytes, bytes.count)
                if count == 0 { break }
                if count > 0 {
                    lastInput = Date()
                    let before = (metrics.cellWidth, metrics.cellHeight, metrics.windowWidth, metrics.windowHeight, metrics.cellScale, metrics.background)
                    let filtered = metrics.feed(Array(bytes.prefix(count)))
                    if before != (metrics.cellWidth, metrics.cellHeight, metrics.windowWidth, metrics.windowHeight, metrics.cellScale, metrics.background) { relayout(clear: true) }
                    handle(parser.feed(filtered))
                }
            } else if Date().timeIntervalSince(lastInput) > 0.1 {
                handle(parser.feed(metrics.feed([], flush: true), flushEscape: true))
            }
            // The probe reply arrives with the cell metrics, typically within a few milliseconds.
            if !graphicsReady, probe == nil || metrics.primaryAttributes != nil || Date().timeIntervalSince(started) > (profile.tmux ? 0.8 : 0.5) {
                let (transport, target) = decideGraphics()
                renderer.configure(placement: nil, transport: transport, target: target)
                probe?.cleanup(); probe = nil
                graphicsReady = true
                relayout(clear: true)
            }
            // Wait briefly for real cell metrics so the first stream is requested at the right size.
            let settled = metrics.cellHeight != nil || cellOverride != nil || Date().timeIntervalSince(started) > 0.4
            if graphicsReady, settled, live == nil, polling == nil, switching == nil {
                if cli.touchAvailable || phone.isDevice { startStream() } else { polling = startPolling() }
            }
            if live != nil { rescaleStreamIfNeeded() }
            if wheelSteps != 0 && Date().timeIntervalSince(wheelAt) >= 0.04 { flushWheel() }
            if liveReady, inFlight == nil, !queue.isEmpty {
                var request = queue.removeFirst(); nextID += 1; request["id"] = nextID
                let label = request["label"] as? String ?? ""; request["label"] = nil
                inputController?.send(request); inFlight = (nextID, label)
            }
            if Date().timeIntervalSince(lastChrome) >= 0.08 { lastChrome = Date(); drawChrome() }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        // An App Store preview is encoded after recording stops; finish it before leaving.
        if recording != nil { stopRecording(wait: false) }
        if let mediaTask { record("Saving the app preview…", ok: true); previousChrome = ""; drawChrome(); await mediaTask.value }
        if let failure { throw Failure(failure) }
    }

    // MARK: Video

    private func startStream() {
        guard let layout else { return }
        let session: PhoneLink = phone.isDevice ? DeviceLiveSession() : PhoneLiveSession()
        live = session; liveReady = false; inFlight = nil
        if case .live = link {} else { link = .connecting(phone.isDevice ? "Connecting to \(phone.displayModel)" : "Starting video stream") }
        streamScale = streamScale(for: layout.viewport)
        session.onFailure = { [weak self] in self?.failure = $0; self?.quit = true }
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event["event"] as? String {
            case "ready": liveReady = true; link = .live
            case "locked":
                phoneLocked = true; queue.removeAll()
                record("\(self.phone.displayModel) is locked. Unlock it to continue.", ok: false)
            case "unlocked": phoneLocked = false; record("\(self.phone.displayModel) unlocked", ok: true)
            case "waiting":
                let message = event["message"] as? String ?? "Waiting for the iPhone"
                link = .waiting(message); queue.removeAll(); record(message, ok: false)
            case "fatal": failure = event["error"] as? String ?? "Live stream failed"; quit = true
            default: break
            }
        }
        let renderer = renderer, scale = streamScale, phone = phone, screen = screen
        Task { @MainActor in
            do {
                if let device = session as? DeviceLiveSession {
                    try await device.start(cli: cli, phone: phone, streamScale: scale) { renderer.submit($0) }
                } else if let simulator = session as? PhoneLiveSession {
                    try await simulator.start(cli: cli, phone: phone, scale: screen.scale, streamScale: scale) { renderer.submit($0) }
                }
            }
            catch { failure = error.localizedDescription; quit = true }
        }
    }
    /// Without idb, poll full-resolution screenshots. Slower, but still sharp.
    private func startPolling() -> Task<Void, Never> {
        link = .polling
        let renderer = renderer, udid = phone.udid
        return Task { @MainActor in
            while !Task.isCancelled && !quit {
                do {
                    renderer.submit(try await cli.simctl(["io", udid, "screenshot", "--type=jpeg", "-"], timeout: 15))
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch { if !Task.isCancelled { failure = error.localizedDescription; quit = true }; break }
            }
        }
    }
    /// Stream just enough pixels for the on-screen phone, in eighths of the native framebuffer.
    private func streamScale(for viewport: PhoneViewport) -> Double {
        let wanted = min(1, max(0.25, (viewport.frame.screenHeight * viewport.scale / Double(screen.nativeHeight) * 8).rounded(.up) / 8))
        // Real iPhones never stream above the cap, so growing past it must not restart anything.
        return phone.isDevice ? min(wanted, DeviceLiveSession.maxScale) : wanted
    }
    /// Restarts the stream when the phone grows past the streamed resolution, or shrinks far below it.
    private func rescaleStreamIfNeeded() {
        guard let layout, liveReady else { return }
        let wanted = streamScale(for: layout.viewport)
        guard wanted > streamScale + 0.01 || wanted < streamScale - 0.26 else { pendingScale = nil; return }
        if pendingScale?.value != wanted { pendingScale = (wanted, Date()); return }
        guard let pending = pendingScale, Date().timeIntervalSince(pending.since) > 0.6, inFlight == nil else { return }
        pendingScale = nil
        if let device = live as? DeviceLiveSession {
            streamScale = wanted
            Task { @MainActor [weak self] in
                do { try await device.rescale(wanted) }
                catch { guard let self, self.live === device else { return }; self.live?.stop(); self.live = nil; self.startStream() }
            }
            return
        }
        live?.stop(); live = nil
        startStream()
    }

    // MARK: Layout

    /// Nothing is drawn until the graphics protocol is chosen, so the phone never flashes in the wrong one.
    private var graphicsReady = false
    private var placement: FramePlacement? {
        guard graphicsReady else { return nil }
        return layout.map { FramePlacement(viewport: $0.viewport, background: graphics == .iterm ? (metrics.background ?? 0x1e1e1e) : nil,
                                    mask: menuArea.map { CellRect(column: $0.column, row: $0.row, columns: $0.width, rows: $0.height) }) }
    }
    private func queryMetrics() { writer.write("\u{1b}[16t\u{1b}[14t\u{1b}]1337;ReportCellSize\u{7}") }
    /// `clear` wipes the screen first; zoom and pan changes only move the image.
    private func relayout(clear: Bool = false) {
        let cols = max(1, Int(size.ws_col)), rows = max(3, Int(size.ws_row))
        let cw = cellOverride?.0 ?? metrics.cellWidth ?? (size.ws_xpixel > 0 ? Double(size.ws_xpixel) / Double(cols) : metrics.windowWidth.map { $0 / Double(cols) }) ?? 8
        let ch = cellOverride?.1 ?? metrics.cellHeight ?? (size.ws_ypixel > 0 ? Double(size.ws_ypixel) / Double(rows) : metrics.windowHeight.map { $0 / Double(rows) }) ?? 16
        // Roomy: two header lines and a divider on top, a three-line toolbar below.
        let roomy = rows >= 20 && cols >= 30
        let top = roomy ? 4 : 2, bottom = roomy ? rows - 3 : rows - 1
        var phoneColumns = cols, phoneRows = max(1, bottom - top + 1), logPanel: CellRect?
        if logTail != nil {
            if cols >= 100 {
                let width = min(110, max(40, cols * 45 / 100))
                logPanel = CellRect(column: cols - width + 1, row: top, columns: width, rows: phoneRows); phoneColumns = cols - width - 1
            } else if phoneRows >= 12 {
                let height = max(5, phoneRows * 2 / 5)
                logPanel = CellRect(column: 1, row: bottom - height + 1, columns: cols, rows: height); phoneRows -= height
            }
        }
        let viewport = PhoneViewport(frame: DeviceFrame(screenWidth: screen.width, screenHeight: screen.height, finish: finish),
                                     column: 1, row: top, columns: phoneColumns, rows: phoneRows,
                                     cellWidth: cw * metrics.cellScale, cellHeight: ch * metrics.cellScale, zoom: zoom, pan: pan)
        let next = Layout(viewport: viewport, columns: cols, rows: rows, roomy: roomy, logPanel: logPanel)
        let palette = Palette.matching(background: metrics.background)
        if palette != Theme.palette { Theme.palette = palette; previousChrome = "" }
        guard clear || next != layout else { return }
        let resized = next.columns != layout?.columns || next.rows != layout?.rows || next.roomy != layout?.roomy
        layout = next
        if clear || resized { writer.write("\u{1b}[0m\u{1b}[2J"); previousChrome = ""; menuArea = nil }
        else if imagesAreText { eraseScreenText() }
        renderer.configure(placement: placement)
        drawChrome()
        renderer.redraw()
        trackCrop()
    }
    /// What part of the framed phone is in view: nil when all of it is.
    private var visibleCrop: MediaRect? { layout?.viewport.visible }
    /// Notes zoom and pan changes while recording, so the saved video follows them.
    private func trackCrop() {
        guard let started = recording?.started, recordingPlan != nil else { return }
        let crop = visibleCrop
        if crop != recordingPlan!.crops.last?.crop { recordingPlan!.crops.append((Date().timeIntervalSince(started), crop)) }
    }
    /// Erases the rows the phone can occupy. Needed where images are cell content (iTerm2).
    private func eraseScreenText() {
        guard let layout else { return }
        let top = layout.roomy ? 4 : 2, bottom = layout.roomy ? layout.rows - 3 : layout.rows - 1
        writer.write((top...max(top, bottom)).map { "\u{1b}[\($0);1H\u{1b}[0m\u{1b}[2K" }.joined())
        previousChrome = ""
    }
    private func setZoom(_ value: Double, resetPan: Bool = false) {
        zoom = min(4, max(0.3, value))
        if resetPan || zoom <= 1 { pan = (0.5, 0.5) }
        relayout()
        let zoomedIn = layout.map { $0.viewport.overflowsX || $0.viewport.overflowsY } ?? false
        record("Zoom \(Int((zoom * 100).rounded()))%" + (zoomedIn ? " · scroll to move around, ⌥ scroll for the app · captures show this view" : ""), ok: true)
    }

    // MARK: Chrome

    private func drawChrome() {
        guard let layout else { return }
        let now = Date(), stats = renderer.currentStats
        if now.timeIntervalSince(fpsSample.at) >= 1 {
            fps = Double(stats.frames - fpsSample.frames) / now.timeIntervalSince(fpsSample.at)
            fpsSample = (stats.frames, now)
        }
        let spin = Theme.spinner[Int(now.timeIntervalSinceReferenceDate * 12) % Theme.spinner.count]
        let cols = layout.columns, v = layout.viewport
        var output = ""
        hits = []

        /// Writes a row from left and right groups, padding between them, and records click targets.
        func row(_ row: Int, left: [([Span], Action?)], right: [([Span], Action?)] = [], from column: Int = 1, width: Int? = nil) {
            let width = width ?? cols - column + 1
            let rightWidth = right.reduce(0) { $0 + $1.0.width }
            var spans: [Span] = [], position = column
            for (group, action) in left {
                let fitted = group.truncated(max(0, width - (position - column) - rightWidth - 1))
                if let action, fitted.width > 0 { hits.append(Hit(row: row, columns: position...(position + fitted.width - 1), action: action)) }
                spans += fitted; position += fitted.width
            }
            if rightWidth > 0, position - column + rightWidth <= width {
                spans.append(Span(String(repeating: " ", count: width - (position - column) - rightWidth)))
                position = column + width - rightWidth
                for (group, action) in right {
                    if let action { hits.append(Hit(row: row, columns: position...(position + group.width - 1), action: action)) }
                    spans += group; position += group.width
                }
            }
            output += Box.line(column: column, row: row, width: width, spans)
        }
        func pressed(_ action: Action) -> Bool { flash?.action == action && now.timeIntervalSince(flash!.at) < 0.18 }

        // Header: "terminal-phone · default ⌄" opens the device menu. On the right, the stream's
        // state and a small zoom control: − and + step, the middle resets to fit (or 1:1 from fit).
        let g = Theme.glyphs
        let title: [Span] = [Span(" terminal-phone", Theme.bold + Theme.text), Span(" · ", Theme.faint),
                             Span(phone.name, Theme.bold + Theme.accent), Span(" " + g.menu, menu != nil ? Theme.accent : Theme.muted)]
        let state: [Span] = switch link {
        case .connecting: [Span("\(spin) Connecting", Theme.yellow)]
        case .waiting: [Span("\(spin) Waiting for iPhone", Theme.yellow)]
        case .live where phoneLocked: [Span(g.live + " ", Theme.yellow), Span("Locked", Theme.yellow)]
        case .polling: [Span(g.live + " ", Theme.cyan), Span("Screenshots", Theme.muted)]
        case .live: [Span(g.live + " ", Theme.green), Span("Live", Theme.text)] + (fps >= 0.5 ? [Span(" · \(Int(fps.rounded())) fps", Theme.muted)] : [])
        }
        let fitted = abs(zoom - 1) < 0.01
        let zoomLabel = fitted ? g.zoomFit : "\(Int((zoom * 100).rounded()))%"
        let zoomControl: [([Span], Action?)] = [
            ([Span("Zoom ", Theme.faint)], nil),
            ([Span(" \(g.zoomOut) ", pressed(.zoomOut) ? Theme.key : Theme.text + Theme.bg(Theme.palette.keyBackground))], .zoomOut),
            ([Span(" \(zoomLabel) ", pressed(fitted ? .zoomActual : .zoomFit) ? Theme.key : Theme.muted)], fitted ? .zoomActual : .zoomFit),
            ([Span(" \(g.zoomIn) ", pressed(.zoomIn) ? Theme.key : Theme.text + Theme.bg(Theme.palette.keyBackground))], .zoomIn), ([Span(" ")], nil)]
        var right: [([Span], Action?)] = [(state, nil)]
        let zoomWidth = zoomControl.reduce(0) { $0 + $1.0.width } + 3
        if title.width + state.width + zoomWidth + 2 <= cols { right += [([Span("   ")], nil)] + zoomControl }
        else if title.width + state.width + 3 <= cols { right += [([Span(" ")], nil)] }
        else { right = [] }
        row(1, left: [(title, .menu)], right: right)
        if layout.roomy {
            let subtitle = [Span("  \(phone.displayModel)", Theme.muted), Span(" · \(phone.displaySystem)\(phone.isDevice ? " · real iPhone" : "")", Theme.faint),
                            Span(readOnly ? " · View only" : " · Interactive", readOnly ? Theme.yellow : Theme.green)]
            row(2, left: [(subtitle, .menu)], right: [(statusLine(now: now, room: cols - subtitle.width - 4), nil)])
            output += "\u{1b}[3;1H" + [Span(String(repeating: "─", count: cols), Theme.border)].rendered
        }

        // Status text drawn on the black screen until video arrives.
        let screenCells = v.screenCells
        let splashRow = screenCells.row + screenCells.rows / 2 - 1
        if stats.frames == 0 || switching != nil {
            let message: String = switch link {
            case .connecting(let text), .waiting(let text): text
            case .polling: "Waiting for a screenshot"
            case .live: "Waiting for the first frame"
            }
            let lines: [[Span]] = [[Span(spin, Theme.accent)], [Span(message, Theme.text)], [Span("\(phone.name) · \(profile.displayName)", Theme.faint)]]
            if screenCells.columns > 4 {
                for (offset, line) in lines.enumerated() {
                    let fitted = line.truncated(screenCells.columns)
                    let pad = max(0, (screenCells.columns - fitted.width) / 2)
                    output += Box.line(column: screenCells.column, row: splashRow + offset, width: screenCells.columns, [Span(String(repeating: " ", count: pad))] + fitted)
                }
            }
            firstFrameShown = false
        } else if !firstFrameShown {
            firstFrameShown = true
            if screenCells.columns > 4 {
                for offset in 0..<3 { output += Box.line(column: screenCells.column, row: splashRow + offset, width: screenCells.columns, []) }
            }
            renderer.redraw()
        }

        // Toolbar: a rounded pill of utility buttons, with labels when there is room.
        let recordLabel: String = recording.map { r in
            let seconds = Int(now.timeIntervalSince(r.started)); return String(format: "Stop %d:%02d", seconds / 60, seconds % 60)
        } ?? "Record"
        var groups: [[(String, String, Action, String)]] = []
        groups.append([(g.home, "Home", .home, readOnly ? Theme.muted : Theme.text), (g.lock, "Lock", .lock, readOnly ? Theme.muted : Theme.text)])
        groups.append([(readOnly ? g.controlOff : g.control, readOnly ? "Enable control" : "Control on", .control, readOnly ? Theme.yellow : Theme.green)])
        groups.append([(g.screenshot, "Screenshot", .screenshot, Theme.text), (recording == nil ? g.record : g.stop, recordLabel, .record, recording == nil ? Theme.text : Theme.red),
                       (g.appStore, "App Store", .appStore, studio != nil ? Theme.accent : Theme.magenta)])
        var look: [(String, String, Action, String)] = [(g.frame, "Frame", .frames, picker != nil ? Theme.accent : Theme.text)]
        if dark != nil && !readOnly { look.append((dark == true ? g.light : g.dark, dark == true ? "Light" : "Dark", .appearance, Theme.text)) }
        groups.append(look)
        groups.append([(g.tools, "Tools", .tools, tools != nil ? Theme.accent : Theme.text), (g.logs, "Logs", .logs, Theme.text)])
        func toolbar(labels: Bool) -> [([Span], Action?)] {
            var items: [([Span], Action?)] = []
            for (index, group) in groups.enumerated() {
                if index > 0 { items.append(([Span(" │ ", Theme.border)], nil)) }
                for (offset, item) in group.enumerated() {
                    if offset > 0 { items.append(([Span(labels ? "  " : " ")], nil)) }
                    let text = labels ? " \(item.0) \(item.1) " : " \(item.0) "
                    items.append(([Span(text, pressed(item.2) ? Theme.key : item.3)], item.2))
                }
            }
            return items
        }
        var items = toolbar(labels: true)
        if items.reduce(0, { $0 + $1.0.width }) + 6 > cols { items = toolbar(labels: false) }
        let barWidth = items.reduce(0) { $0 + $1.0.width } + 4
        if layout.roomy, barWidth <= cols {
            let left = (cols - barWidth) / 2 + 1, top = layout.rows - 2
            output += "\u{1b}[\(top);1H\u{1b}[2K\u{1b}[\(top + 2);1H\u{1b}[2K\u{1b}[\(top + 1);1H\u{1b}[2K"
            output += Box.frame(column: left, row: top, width: barWidth, height: 3)
            row(top + 1, left: [([Span(" ")], nil)] + items + [([Span(" ")], nil)], from: left + 1, width: barWidth - 2)
        } else {
            row(layout.rows, left: [([Span(" ")], nil)] + items, right: [(statusLine(now: now, room: 30), nil)])
        }

        let maskBefore = menuArea.map { [$0.column, $0.row, $0.width, $0.height] }
        if let panel = layout.logPanel { output += drawLogs(panel) }
        if let menu { output += drawMenu(menu) } else if picker != nil { output += drawFramePicker() } else if tools != nil { output += drawTools() }
        else if studio != nil { output += drawStudio() }
        if menuArea.map({ [$0.column, $0.row, $0.width, $0.height] }) != maskBefore { renderer.configure(placement: placement) }

        guard output != previousChrome else { return }
        previousChrome = output
        writer.write(output)
    }

    /// The latest action result, or shortcut hints.
    private func statusLine(now: Date, room: Int) -> [Span] {
        if let last = activity.last, now.timeIntervalSince(last.at) < (last.ok ? 2.5 : 6) {
            let toast = [Span(last.ok ? Theme.glyphs.check + " " : Theme.glyphs.cross + " ", last.ok ? Theme.green : Theme.red), Span(last.text, last.ok ? Theme.text : Theme.red)] +
                (last.milliseconds.map { [Span(" · \(Int($0.rounded())) ms", Theme.faint)] } ?? []) + [Span(" ")]
            return toast.truncated(max(0, room))
        }
        let hint: [Span] = [Span("⌃]", Theme.cyan), Span(" quit ", Theme.faint)]
        return hint.width <= room ? hint : []
    }

    /// A dropdown of registered phones under the title. Every cell has a background so it covers the phone image.
    private func drawMenu(_ items: [MenuItem]) -> String {
        guard let layout else { return "" }
        let surface = Theme.surface, selected = Theme.selected
        let width = min(layout.columns - 2, max(36, (items.map { $0.name.count + $0.detail.count + $0.state.count + 10 }.max() ?? 0)))
        let height = min(layout.rows - 2, max(1, items.count) + 3)
        let column = 2, top = 2
        var output = ""
        func paint(_ row: Int, _ spans: [Span], background: String) {
            let fitted = spans.truncated(width)
            output += "\u{1b}[\(row);\(column)H" + fitted.map { Span($0.text, background + $0.style) }.rendered +
                [Span(String(repeating: " ", count: max(0, width - fitted.width)), background)].rendered
        }
        paint(top, [Span("╭─ ", Theme.border), Span("Phones", Theme.bold + Theme.accent), Span(" " + String(repeating: "─", count: max(0, width - 12)) + "╮", Theme.border)], background: surface)
        for (index, item) in items.prefix(height - 3).enumerated() {
            let current = item.name == phone.name, background = index == menuIndex ? selected : surface
            let state = ["Booted", "Connected"].contains(item.state) ? Span(Theme.glyphs.live + " ", Theme.green) : Span(Theme.glyphs.idle + " ", Theme.faint)
            let left: [Span] = [Span("│ ", Theme.border), Span(current ? "✓ " : "  ", Theme.accent), state, Span(item.name, Theme.bold + Theme.text), Span("  " + item.detail, Theme.muted)]
            let tail = [Span(item.state.lowercased() + " ", Theme.faint), Span("│", Theme.border)]
            paint(top + 1 + index, left + [Span(String(repeating: " ", count: max(1, width - left.width - tail.width)))] + tail, background: background)
            hits.insert(Hit(row: top + 1 + index, columns: column...(column + width - 1), action: .select(item.name)), at: 0)
        }
        if items.isEmpty { paint(top + 1, [Span("│ ", Theme.border), Span("Loading…", Theme.faint)], background: surface) }
        let tip = [Span("│ ", Theme.border), Span("+ ", Theme.accent), Span("terminal-phone up NAME", Theme.cyan), Span(" adds a phone", Theme.faint)]
        paint(top + height - 2, tip + [Span(String(repeating: " ", count: max(1, width - tip.width - 1))), Span("│", Theme.border)], background: surface)
        paint(top + height - 1, [Span("╰" + String(repeating: "─", count: max(0, width - 2)) + "╯", Theme.border)], background: surface)
        menuArea = (column, top, width, height)
        return output
    }

    /// The frame picker: a swatch and name per finish, beside the phone. Moving through it
    /// previews each finish on the phone itself.
    private func drawFramePicker() -> String {
        guard let layout, let picker else { return "" }
        let surface = Theme.surface, selected = Theme.selected
        let all = FrameFinish.allCases, width = min(layout.columns - 2, 30)
        let top = layout.roomy ? 4 : 2
        let visible = max(1, min(all.count, layout.rows - top - 3))
        let first = min(max(0, picker.index - visible + 1), all.count - visible)
        let column = 2
        var output = ""
        func paint(_ row: Int, _ spans: [Span], background: String) {
            let fitted = spans.truncated(width)
            output += "\u{1b}[\(row);\(column)H" + fitted.map { Span($0.text, background + $0.style) }.rendered +
                [Span(String(repeating: " ", count: max(0, width - fitted.width)), background)].rendered
        }
        paint(top, [Span("╭─ ", Theme.border), Span("Frame", Theme.bold + Theme.accent), Span(" " + String(repeating: "─", count: max(0, width - 11)) + "╮", Theme.border)], background: surface)
        for (offset, option) in all[first..<(first + visible)].enumerated() {
            let index = first + offset, row = top + 1 + offset
            let left: [Span] = [Span("│ ", Theme.border), Span("██", Theme.fg(option.band)), Span(" "), Span(option.displayName, (option == finish ? Theme.bold : "") + Theme.text)]
            let tail = [Span(option == picker.original ? Theme.glyphs.check + " " : "  ", Theme.accent), Span("│", Theme.border)]
            paint(row, left + [Span(String(repeating: " ", count: max(1, width - left.width - tail.width)))] + tail, background: index == picker.index ? selected : surface)
            hits.insert(Hit(row: row, columns: column...(column + width - 1), action: .pickFrame(option)), at: 0)
        }
        let help = [Span("│ ", Theme.border), Span("↑↓", Theme.cyan), Span(" try ", Theme.faint), Span("⏎", Theme.cyan), Span(" keep ", Theme.faint), Span("esc", Theme.cyan), Span(" undo", Theme.faint)]
        paint(top + visible + 1, help + [Span(String(repeating: " ", count: max(1, width - help.width - 1))), Span("│", Theme.border)], background: surface)
        paint(top + visible + 2, [Span("╰" + String(repeating: "─", count: max(0, width - 2)) + "╯", Theme.border)], background: surface)
        menuArea = (column, top, width, visible + 3)
        return output
    }

    private func record(_ text: String, ok: Bool, milliseconds: Double? = nil) {
        activity.append(Activity(at: Date(), text: text, ok: ok, milliseconds: milliseconds))
        if activity.count > 50 { activity.removeFirst(activity.count - 50) }
    }

    // MARK: Actions

    static func savedFrame(for phone: String, store: PhoneStore) -> FrameFinish {
        (try? PhoneConfiguration.load(store: store))?.frame(for: phone) ?? .graphite
    }
    static func saveFrame(_ finish: FrameFinish, for phone: String, store: PhoneStore) {
        guard var config = try? PhoneConfiguration.load(store: store) else { return }
        config.setFrame(finish, for: phone); try? config.save(store: store)
    }
    private func openFramePicker() {
        if menu != nil || tools != nil || studio != nil { closeMenu() }
        picker = (finish, FrameFinish.allCases.firstIndex(of: finish) ?? 0)
        previousChrome = ""
    }
    /// Shows a finish on the phone without saving it.
    private func previewFrame(_ option: FrameFinish) {
        if picker != nil { picker!.index = FrameFinish.allCases.firstIndex(of: option) ?? 0 }
        previousChrome = ""
        guard option != finish else { return }
        finish = option
        relayout()
    }
    /// Closes the picker, keeping the previewed finish or going back to the one it opened with.
    private func closeFramePicker(keep: Bool) {
        guard let original = picker?.original else { return }
        closeMenu()
        if !keep { previewFrame(original); return }
        guard finish != original else { return }
        Self.saveFrame(finish, for: phone.name, store: cli.store)
        record("Frame: \(finish.displayName)", ok: true)
    }

    private func perform(_ action: Action) {
        flash = (action, Date())
        switch action {
        case .menu: menu == nil ? openMenu() : closeMenu()
        case .frames: picker == nil ? openFramePicker() : closeFramePicker(keep: true)
        case .pickFrame(let option): previewFrame(option)
        case .select(let name): closeMenu(); switchPhone(to: name)
        case .zoomOut: setZoom(Self.zoomSteps.last(where: { $0 < zoom - 0.001 }) ?? 0.3)
        case .zoomIn: setZoom(Self.zoomSteps.first(where: { $0 > zoom + 0.001 }) ?? 4)
        case .zoomFit: setZoom(1, resetPan: true)
        // One simulator framebuffer pixel per screen pixel.
        case .zoomActual: if let layout { setZoom(screen.scale / layout.viewport.fitScale, resetPan: true) }
        case .home: enqueue("button", ["HOME"], label: "home")
        case .lock: enqueue("button", ["LOCK"], label: "lock")
        case .screenshot: screenshot()
        case .record: recording == nil ? startRecording() : stopRecording(wait: false)
        case .appearance: toggleAppearance()
        case .tools: tools == nil ? openTools() : closeMenu()
        case .tool(let tool): if let index = toolList().firstIndex(where: { $0.tool == tool }) { tools = index }; runTool(tool)
        case .logs: openLogs()
        case .appStore: studio == nil ? openStudio() : closeMenu()
        case .studio(let item): if let index = studioRows().firstIndex(where: { $0.item == item }) { studio = index }; runStudio(item, step: 0)
        case .control:
            if !phone.acceptsInput {
                record("Real iPhone input needs owner approval. Run terminal-phone connect.", ok: false)
            } else if !phone.isDevice && !cli.touchAvailable {
                record("Touch control needs setup. Run terminal-phone setup.", ok: false)
            } else {
                viewOnly.toggle(); queue.removeAll(); anchor = nil; wheelSteps = 0
                record(viewOnly ? "View only — select Enable control to interact" : "Control enabled — click, drag or scroll", ok: true)
            }
        }
    }
    private static let zoomSteps = [0.3, 0.5, 0.67, 0.8, 1, 1.25, 1.5, 2, 3, 4]

    private func openMenu() {
        if picker != nil { closeFramePicker(keep: true) }
        if tools != nil || studio != nil { closeMenu() }
        menu = []; menuIndex = 0
        Task { @MainActor in
            let catalog = try? await cli.catalog()
            let devices = try? await PhoneDevices.list(cli)
            let items = ((try? cli.store.names()) ?? []).compactMap { name -> MenuItem? in
                guard let saved = try? cli.store.load(name) else { return nil }
                let state = saved.isDevice
                    ? devices?.first(where: { $0.identifier.caseInsensitiveCompare(saved.udid) == .orderedSame }).map { $0.reachable ? "Connected" : "Offline" } ?? "Unpaired"
                    : catalog.flatMap { try? $0.device(for: saved).state } ?? "Unavailable"
                return MenuItem(name: name, detail: "\(saved.displayModel) · \(saved.displaySystem)", state: state)
            }
            guard menu != nil else { return }
            menu = items; menuIndex = items.firstIndex(where: { $0.name == phone.name }) ?? 0
        }
    }
    private func closeMenu() {
        guard menu != nil || picker != nil || tools != nil || studio != nil else { return }
        menu = nil; picker = nil; tools = nil; studio = nil; captionDraft = nil
        if let area = menuArea {
            // Default-background spaces let the phone image show through again.
            writer.write((area.row..<(area.row + area.height)).map { "\u{1b}[\($0);\(area.column)H\u{1b}[0m" + String(repeating: " ", count: area.width) }.joined())
        }
        menuArea = nil; previousChrome = ""
        renderer.configure(placement: placement)
        if imagesAreText { renderer.redraw() }
    }

    /// Boots the chosen phone if needed and moves the stream to it. The previous phone keeps running.
    private func switchPhone(to name: String) {
        guard name != phone.name, switching == nil else { return }
        stopRecording(wait: false)
        if logTail != nil { closeLogs() }
        live?.stop(); live = nil; polling?.cancel(); polling = nil
        liveReady = false; queue.removeAll(); inFlight = nil
        link = .connecting("Opening \(name)")
        switching = Task { @MainActor in
            defer { switching = nil }
            do {
                let saved = try cli.store.load(name)
                if saved.isDevice {
                    link = .connecting("Connecting to \(saved.displayModel)")
                    screen = try await PhoneDevices.connect(cli, saved, progress: false).screen()
                } else {
                    let catalog = try await cli.catalog()
                    if try catalog.device(for: saved).state == "Shutdown" {
                        link = .connecting("Booting \(name)")
                        _ = try await cli.simctl(["boot", saved.udid])
                    }
                    _ = try await cli.simctl(["bootstatus", saved.udid, "-b"], timeout: 240)
                    screen = try cli.screen(saved, catalog: catalog)
                }
                phone = saved; zoom = 1; pan = (0.5, 0.5); dark = nil
                finish = Self.savedFrame(for: saved.name, store: cli.store)
                try cli.rememberPhone(saved.name)
                configureInput()
                renderer.reset()
                relayout(clear: true)
                refreshAppearance()
                record("switched to \(name)", ok: true)
            } catch { record("Cannot open \(name): \(error.localizedDescription)", ok: false) }
            link = .connecting("Starting video stream")
        }
    }

    private func outputURL(_ kind: String, _ ext: String) -> URL {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let folder = FileManager.default.fileExists(atPath: desktop.path) ? desktop : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"; return f.string(from: Date()) }()
        return folder.appendingPathComponent("terminal-phone \(phone.name) \(kind) \(stamp).\(ext)")
    }
    private func screenshot() {
        // Zoomed in: save what is in view, in the frame, on a transparent background.
        if let crop = visibleCrop {
            capture(MediaStyle(frame: finish, background: .transparent, crop: crop), kind: "zoomed screenshot"); return
        }
        let url = outputURL("screenshot", "png"), udid = phone.udid, device = phone.isDevice ? phone : nil
        Task { @MainActor in
            do {
                if let device { try await PhoneDevices.connect(cli, device, progress: false).screenshot().write(to: url, options: .atomic) }
                else { _ = try await cli.simctl(["io", udid, "screenshot", "--type=png", url.path], timeout: 20) }
                record("saved \(url.lastPathComponent)", ok: true)
            }
            catch { record("Screenshot failed: \(error.localizedDescription)", ok: false) }
        }
    }
    /// Records the screen, and the input during it as a flow that `terminal-phone replay` runs again.
    /// Everything records to a temporary movie first: an App Store preview, or a recording made
    /// while zoomed in, is composed when it stops; anything else is moved to the Desktop as it is.
    private func startRecording(appStore: Bool = false) {
        guard recording == nil, !startingRecording, mediaTask == nil else {
            if mediaTask != nil { record("Still saving the last recording…", ok: false) }
            return
        }
        startingRecording = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-phone-\(UUID().uuidString).mov")
        let crop = visibleCrop
        let plan = RecordingPlan(appStore: appStore, style: appStore ? studioSettings.style(finish: finish, crop: crop) : nil,
                                 points: Double(min(screen.width, screen.height)), crops: [(0, crop)])
        let phone = phone
        Task { @MainActor in
            defer { startingRecording = false }
            do {
                let started = try await PhoneRecording.start(cli: cli, phone: phone, movie: url)
                guard phone.name == self.phone.name, !quit else { started.stop(); return }
                recording = started; recordingPlan = plan
                record(appStore ? "Recording the app preview — App Store wants 15–30 s" : crop != nil ? "Recording this zoomed view…" : "recording…", ok: true)
            } catch { record("Recording failed: \(error.localizedDescription)", ok: false) }
        }
    }
    private func stopRecording(wait: Bool) {
        guard let current = recording, let plan = recordingPlan else { return }
        recording = nil; recordingPlan = nil
        let seconds = Date().timeIntervalSince(current.started), movie = current.movie
        let zoomed = plan.crops.contains { $0.crop != nil }
        // A plain recording that never zoomed is kept exactly as recorded.
        guard plan.appStore || zoomed else {
            let output = outputURL("recording", "mov")
            let flow = current.stop(flowNextTo: output)
            do { try FileManager.default.moveItem(at: movie, to: output); lastMedia = output; record("saved \(output.lastPathComponent)\(flow == nil ? "" : " + flow")", ok: true) }
            catch { record("Recording failed: \(error.localizedDescription)", ok: false) }
            return
        }
        // Zoomed plain recordings keep the frame and a transparent background, so they drop into
        // any edit; the first zoomed view sets the clip's size.
        let firstCrop = plan.crops.first { $0.crop != nil }?.crop
        let style = plan.style ?? MediaStyle(frame: finish, background: .transparent, crop: firstCrop)
        let output = !plan.appStore ? outputURL("zoomed recording", "mov")
            : style.size == .native ? outputURL("video", style.transparent ? "mov" : "mp4") : outputURL("App Store preview", "mp4")
        _ = current.stop(flowNextTo: output)
        record(plan.appStore ? "Encoding the app preview…" : "Saving the zoomed recording…", ok: true)
        var appStoreSize = false
        if case .appStore = style.size { appStoreSize = true }
        let crops = plan.crops, points = plan.points, appStore = appStoreSize
        mediaTask = Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: movie); mediaTask = nil; previousChrome = "" }
            do {
                // Encoding takes a few seconds; keep the viewer responsive meanwhile.
                let result = try await Task.detached {
                    try await MediaVideoExport.export(movie, to: output, style: style, pointWidth: points, recordedSeconds: seconds,
                                                      maxSeconds: appStore ? AppPreviewRules.maximumSeconds : nil, crops: crops)
                }.value
                lastMedia = output
                if appStore && result.seconds < AppPreviewRules.minimumSeconds {
                    record("Saved \(output.lastPathComponent), but it is \(Int(result.seconds)) s — App Store needs 15–30 s", ok: false)
                } else { record("Saved \(output.lastPathComponent) · \(result.size.width)×\(result.size.height)", ok: true) }
            } catch { record("Saving the video failed: \(error.localizedDescription)", ok: false) }
        }
    }
    private func refreshAppearance() {
        // A real iPhone can't report its appearance, so the toggle stays hidden there.
        guard !phone.isDevice else { dark = nil; return }
        let udid = phone.udid
        Task { @MainActor in
            let value = (try? await cli.simctl(["ui", udid, "appearance"], timeout: 10)).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard udid == phone.udid else { return }
            dark = value == "dark" ? true : value == "light" ? false : nil
        }
    }
    private func toggleAppearance() {
        guard !readOnly, let dark else { return }
        let udid = phone.udid, target = dark ? "light" : "dark"
        Task { @MainActor in
            do { _ = try await cli.simctl(["ui", udid, "appearance", target], timeout: 10); self.dark = !dark; record("\(target) mode", ok: true) }
            catch { record("Appearance failed: \(error.localizedDescription)", ok: false) }
        }
    }

    // MARK: Input

    private func configureInput() {
        inputController?.stop()
        let controller = PhoneViewerInput(cli: cli, phone: phone)
        controller.onEvent = { [weak self] event in
            guard let self, let current = inFlight, event["id"] as? Int == current.id else { return }
            inFlight = nil
            let error = event["error"] as? String
            if error != nil { queue.removeAll() }
            record(error.map { "\(current.label): \($0)" } ?? current.label, ok: error == nil, milliseconds: event["milliseconds"] as? Double)
        }
        inputController = controller
    }

    private func enqueue(_ action: String, _ values: [String], label: String, duration: Double? = nil, wheel: Bool = false) {
        guard !readOnly else { record("View only — select Enable control to interact", ok: false); return }
        if phoneLocked { record("\(phone.displayModel) is locked. Unlock it to continue.", ok: false); return }
        if case .waiting(let message) = link { record(message, ok: false); return }
        if action == "type", queue.last?["action"] as? String == "type", let previous = queue.last?["values"] as? [String], previous[0].utf8.count + values[0].utf8.count < 32768 {
            let text = previous[0] + values[0]
            queue[queue.count - 1]["values"] = [text]; queue[queue.count - 1]["label"] = Self.typeLabel(text); return
        }
        guard queue.count < 32 else { record("Input is busy; wait for pending gestures", ok: false); return }
        var request: [String: Any] = ["action": action, "values": values, "label": label]
        if let duration { request["duration"] = duration }
        if wheel {
            request["wheel"] = true
            if queue.last?["wheel"] as? Bool == true { queue[queue.count - 1] = request; return }
        }
        queue.append(request)
    }
    private static func typeLabel(_ text: String) -> String { "type “\(text.count > 16 ? text.prefix(15) + "…" : text)”" }
    private func handle(_ events: [TerminalEvent]) {
        var text = ""
        func flush() { if !text.isEmpty { enqueue("type", [text], label: Self.typeLabel(text)); text = "" } }
        for event in events {
            if case .quit = event { quit = true; return }
            // While the device menu is open, the keyboard drives it.
            if let items = menu {
                switch event {
                case .key("up"): menuIndex = max(0, menuIndex - 1)
                case .key("down"): menuIndex = min(max(0, items.count - 1), menuIndex + 1)
                case .key("return"): if items.indices.contains(menuIndex) { perform(.select(items[menuIndex].name)) }
                case .key("escape"), .key("ctrl+p"): closeMenu()
                case .mouse: handleMouse(event)
                default: break
                }
                continue
            }
            if captionDraft != nil {
                switch event {
                case .text(let value): captionDraft! += value; previousChrome = ""
                case .key("backspace"): if !captionDraft!.isEmpty { captionDraft!.removeLast() }; previousChrome = ""
                case .key("return"): commitCaption()
                case .key("escape"): captionDraft = nil; previousChrome = ""
                case .mouse: handleMouse(event)
                default: break
                }
                continue
            }
            if let index = studio {
                let rows = studioRows()
                switch event {
                case .key("up"): studio = max(0, index - 1); previousChrome = ""
                case .key("down"): studio = min(rows.count - 1, index + 1); previousChrome = ""
                case .key("left"): if rows.indices.contains(index) { runStudio(rows[index].item, step: -1) }
                case .key("right"): if rows.indices.contains(index) { runStudio(rows[index].item, step: 1) }
                case .key("return"): if rows.indices.contains(index) { runStudio(rows[index].item, step: 0) }
                case .key("escape"), .key("ctrl+a"): closeMenu()
                case .key("ctrl+r"): perform(.record)
                case .mouse: handleMouse(event)
                default: break
                }
                continue
            }
            if let index = tools {
                let count = toolList().count
                switch event {
                case .key("up"): tools = max(0, index - 1); previousChrome = ""
                case .key("down"): tools = min(count - 1, index + 1); previousChrome = ""
                case .key("return"): if toolList().indices.contains(index) { runTool(toolList()[index].tool) }
                case .key("escape"), .key("ctrl+t"): closeMenu()
                case .key("ctrl+o"): closeMenu(); openLogs()
                case .mouse: handleMouse(event)
                default: break
                }
                continue
            }
            // The frame picker previews as you move through it.
            if let open = picker {
                let all = FrameFinish.allCases
                switch event {
                case .key("up"): previewFrame(all[max(0, open.index - 1)])
                case .key("down"): previewFrame(all[min(all.count - 1, open.index + 1)])
                case .key("return"), .key("ctrl+f"): closeFramePicker(keep: true)
                case .key("escape"): closeFramePicker(keep: false)
                case .mouse: handleMouse(event)
                default: break
                }
                continue
            }
            if case .text(let value) = event { if !readOnly { text += value }; continue }
            flush()
            switch event {
            case .key(let key):
                switch key {
                case "ctrl+p": perform(.menu)
                case "ctrl+s": perform(.screenshot)
                case "ctrl+r": perform(.record)
                case "ctrl+b": perform(.home)
                case "ctrl+l": perform(.lock)
                case "ctrl+f": perform(.frames)
                case "ctrl+t": perform(.tools)
                case "ctrl+o": perform(.logs)
                case "ctrl+a": perform(.appStore)
                default:
                    if let code = ["return": 40, "escape": 41, "backspace": 42, "tab": 43, "delete": 76, "right": 79, "left": 80, "down": 81, "up": 82][key] { enqueue("key", [String(code)], label: "key \(key)") }
                }
            case .mouse: handleMouse(event)
            default: break
            }
        }
        flush()
    }
    private func handleMouse(_ event: TerminalEvent) {
        guard case .mouse(let button, let col, let row, let released) = event, let layout else { return }
        let wheel = button & 64 != 0, motion = button & 32 != 0, shift = button & 4 != 0
        // Chrome buttons act on press; their release is swallowed.
        if !wheel, !motion, !released, button & 3 == 0 {
            if let hit = hits.first(where: { $0.row == row && $0.columns.contains(col) }) { pressedChrome = true; perform(hit.action); return }
            if picker != nil { closeFramePicker(keep: true); pressedChrome = true; return }
            if menu != nil || tools != nil || studio != nil { closeMenu(); pressedChrome = true; return }
        }
        if pressedChrome { if released { pressedChrome = false }; return }
        let viewport = layout.viewport
        if wheel {
            // A zoomed-in phone scrolls around with the wheel (sideways wheels and Shift+wheel move
            // across); ⌥ (Option) + wheel, or any wheel when the whole phone shows, scrolls the app.
            let horizontal = button & 3 >= 2, option = button & 8 != 0
            if (viewport.overflowsX || viewport.overflowsY) && !option {
                let step = viewport.panStep(), sign = button & 1 == 0 ? -1.0 : 1.0
                if (horizontal || shift || !viewport.overflowsY) && viewport.overflowsX { pan.x = min(1, max(0, pan.x + sign * step.x)) }
                else if viewport.overflowsY { pan.y = min(1, max(0, pan.y + sign * step.y)) }
                relayout(); return
            }
            if horizontal { return }
            guard let point = viewport.point(column: col, row: row) else { return }
            if wheelSteps == 0 { wheelAt = Date() }
            wheelSteps = max(-6, min(6, wheelSteps + (button & 1 == 0 ? 1 : -1))); wheelPoint = point
            return
        }
        guard !readOnly, let point = viewport.point(column: col, row: row, clamp: anchor != nil) else { if released { anchor = nil }; return }
        if released {
            if let start = anchor {
                if hypot(Double(point.0 - start.x), Double(point.1 - start.y)) >= 10 {
                    let arrow = abs(point.1 - start.y) >= abs(point.0 - start.x) ? (point.1 < start.y ? "↑" : "↓") : (point.0 < start.x ? "←" : "→")
                    enqueue("swipe", [String(start.x), String(start.y), String(point.0), String(point.1)], label: "swipe \(arrow)",
                            duration: min(0.35, max(0.1, Date().timeIntervalSince(start.at) * 0.35)))
                } else { enqueue("tap", [String(point.0), String(point.1)], label: "tap \(point.0),\(point.1)") }
            }
            anchor = nil
        } else if !motion && button & 3 == 0 { anchor = (point.0, point.1, Date()) }
    }
    private func flushWheel() {
        let height = screen.height
        let distance = min(height / 2, max(40, abs(wheelSteps) * height / 10)), sign = wheelSteps > 0 ? 1 : -1
        let start = max(1, min(height - 2, wheelPoint.1 - sign * distance / 2))
        let end = max(1, min(height - 2, start + sign * distance))
        enqueue("swipe", [String(wheelPoint.0), String(start), String(wheelPoint.0), String(end)], label: "scroll \(sign > 0 ? "↑" : "↓")", duration: 0.16, wheel: true); wheelSteps = 0
    }
}

// MARK: Tools panel

/// Simulator controls (and the few a real iPhone allows), one click or Return each.
extension PhoneViewer {
    fileprivate enum Tool: Equatable { case statusBar, dark, deviceDark, deviceLight, textLarger, textSmaller, location, push, grant, resetPermissions, logs }
    fileprivate struct ToolRow { let tool: Tool; let name: String; let detail: String; let enabled: Bool }
    fileprivate static let places: [(name: String, coordinate: String)] = [
        ("Cupertino", "37.3349,-122.0090"), ("New York", "40.7580,-73.9855"), ("London", "51.5072,-0.1276"),
        ("Tokyo", "35.6595,139.7005"), ("Bengaluru", "12.9716,77.5946")]

    /// The app `terminal-phone run` last launched on this phone.
    fileprivate var lastApp: String? {
        guard let directory = try? cli.store.directory(phone.name),
              let text = try? String(contentsOf: directory.appendingPathComponent("last-app"), encoding: .utf8) else { return nil }
        let bundle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return bundle.isEmpty ? nil : bundle
    }

    fileprivate func toolList() -> [ToolRow] {
        if phone.isDevice {
            let canChange = phone.acceptsInput && !viewOnly
            return [ToolRow(tool: .deviceDark, name: "Dark appearance", detail: canChange ? "" : "needs control", enabled: canChange),
                    ToolRow(tool: .deviceLight, name: "Light appearance", detail: canChange ? "" : "needs control", enabled: canChange),
                    ToolRow(tool: .logs, name: "Show app logs", detail: "relaunches the app", enabled: canChange)]
        }
        let canChange = !viewOnly, app = lastApp
        let place = locationIndex.map { Self.places[$0].name } ?? "not set"
        return [
            ToolRow(tool: .statusBar, name: "Clean status bar", detail: statusBarClean == nil ? "…" : statusBarClean! ? "on · 9:41" : "off", enabled: canChange),
            ToolRow(tool: .dark, name: "Dark mode", detail: dark == nil ? "…" : dark! ? "on" : "off", enabled: canChange && dark != nil),
            ToolRow(tool: .textLarger, name: "Larger text", detail: textSize ?? "…", enabled: canChange),
            ToolRow(tool: .textSmaller, name: "Smaller text", detail: textSize ?? "…", enabled: canChange),
            ToolRow(tool: .location, name: "Location", detail: place, enabled: canChange),
            ToolRow(tool: .push, name: "Test notification", detail: app ?? "run an app first", enabled: canChange && app != nil),
            ToolRow(tool: .grant, name: "Allow all permissions", detail: app ?? "run an app first", enabled: canChange && app != nil),
            ToolRow(tool: .resetPermissions, name: "Reset permissions", detail: app ?? "run an app first", enabled: canChange && app != nil),
            ToolRow(tool: .logs, name: "Show logs", detail: app ?? "all processes", enabled: true),
        ]
    }

    fileprivate func openTools() {
        if menu != nil || picker != nil || studio != nil { closeMenu() }
        tools = 0; previousChrome = ""
        guard !phone.isDevice else { return }
        let udid = phone.udid
        refreshAppearance()
        Task { @MainActor in
            let overrides = (try? await cli.simctl(["status_bar", udid, "list"], timeout: 10)).map { String(decoding: $0, as: UTF8.self) }
            let size = (try? await cli.simctl(["ui", udid, "content_size"], timeout: 10)).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard udid == phone.udid else { return }
            statusBarClean = overrides.map { $0.contains("9:41") }; textSize = size; previousChrome = ""
        }
    }

    fileprivate func runTool(_ tool: Tool) {
        guard let row = toolList().first(where: { $0.tool == tool }) else { return }
        guard row.enabled else {
            record(viewOnly ? "View only — select Enable control first" : "\(row.name): \(row.detail)", ok: false); return
        }
        if tool == .logs { closeMenu(); openLogs(); return }
        if tool == .dark { toggleAppearance(); return }
        guard !toolBusy else { return }
        toolBusy = true
        let udid = phone.udid, saved = phone, app = lastApp
        Task { @MainActor in
            defer { toolBusy = false; previousChrome = "" }
            do {
                switch tool {
                case .statusBar:
                    let clean = !(statusBarClean ?? false)
                    if clean {
                        _ = try await cli.simctl(["status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
                                                  "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "", "--batteryState", "charged", "--batteryLevel", "100"])
                    } else { _ = try await cli.simctl(["status_bar", udid, "clear"]) }
                    statusBarClean = clean; record(clean ? "Status bar: 9:41, full battery" : "Status bar restored", ok: true)
                case .textLarger, .textSmaller:
                    _ = try await cli.simctl(["ui", udid, "content_size", tool == .textLarger ? "increment" : "decrement"])
                    textSize = String(decoding: try await cli.simctl(["ui", udid, "content_size"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    record("Text size: \(textSize ?? "")", ok: true)
                case .location:
                    // Each press moves on to the next place; after the last, the location is cleared.
                    let next = locationIndex.map { $0 + 1 } ?? 0
                    if next < Self.places.count {
                        _ = try await cli.simctl(["location", udid, "set", Self.places[next].coordinate])
                        locationIndex = next; record("Location: \(Self.places[next].name)", ok: true)
                    } else {
                        _ = try await cli.simctl(["location", udid, "clear"]); locationIndex = nil; record("Location cleared", ok: true)
                    }
                case .push:
                    guard let app else { return }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-phone-push-\(UUID().uuidString).json")
                    defer { try? FileManager.default.removeItem(at: file) }
                    try JSONSerialization.data(withJSONObject: ["aps": ["alert": ["title": "terminal-phone", "body": "Test notification"], "sound": "default"]]).write(to: file)
                    _ = try await cli.simctl(["push", udid, app, file.path])
                    record("Notification sent to \(app)", ok: true)
                case .grant, .resetPermissions:
                    guard let app else { return }
                    _ = try await cli.simctl(["privacy", udid, tool == .grant ? "grant" : "reset", "all", app])
                    record(tool == .grant ? "\(app) may use everything" : "\(app) will ask for permissions again", ok: true)
                case .deviceDark, .deviceLight:
                    try await PhoneDevices.connect(cli, saved, progress: false).appearance(dark: tool == .deviceDark)
                    record(tool == .deviceDark ? "Dark appearance" : "Light appearance", ok: true)
                case .dark, .logs: break
                }
            } catch { record("\(row.name): \(error.localizedDescription)", ok: false) }
        }
    }

    /// Opens or closes the logs panel. It streams the app `terminal-phone run` last launched (or, on a
    /// real iPhone, the app on screen), and every process on a simulator with no app yet.
    fileprivate func openLogs() {
        if logTail != nil { closeLogs(); return }
        let saved = phone
        if saved.isDevice, !(saved.acceptsInput && !viewOnly) {
            record("Logs on a real iPhone relaunch the app, which needs control", ok: false); return
        }
        var bundle = lastApp
        Task { @MainActor in
            if saved.isDevice && bundle == nil {
                // Otherwise the app on screen, unless that's the Home Screen.
                let info = try? await PhoneDevices.connect(cli, saved, progress: false).call("GET", "/wda/activeAppInfo") as? [String: Any]
                bundle = (info?["bundleId"] as? String).flatMap { $0 == "com.apple.springboard" ? nil : $0 }
                guard bundle != nil else { record("Open an app on the iPhone first, then choose Logs", ok: false); return }
            }
            guard saved.name == phone.name, logTail == nil else { return }
            do {
                logTail = try PhoneLogTail(executable: cli.xcrun, arguments: await cli.logStreamArguments(saved, bundle: bundle))
                logTitle = bundle ?? "all processes"
                if saved.isDevice { record("Relaunched \(bundle!) to show its output", ok: true) }
                relayout(clear: true)
            } catch { record("Logs: \(error.localizedDescription)", ok: false) }
        }
    }
    fileprivate func closeLogs() {
        logTail?.stop(); logTail = nil
        relayout(clear: true)
    }

    fileprivate func drawLogs(_ panel: CellRect) -> String {
        guard panel.columns >= 12, panel.rows >= 3 else { return "" }
        let snapshot = logTail?.snapshot ?? (lines: [], version: 0, ended: nil)
        let width = panel.columns, inner = width - 4
        var output = ""
        let close = " ⌃O close "
        let title = [Span("╭─ ", Theme.border), Span("Logs", Theme.bold + Theme.accent), Span(" · " + logTitle + " ", Theme.muted)].truncated(width - close.count - 2)
        output += Box.line(column: panel.column, row: panel.row, width: width,
                           title + [Span(String(repeating: "─", count: max(0, width - title.width - close.count - 1)), Theme.border), Span(close, Theme.faint), Span("╮", Theme.border)])
        hits.insert(Hit(row: panel.row, columns: panel.column...(panel.column + width - 1), action: .logs), at: 0)
        let room = panel.rows - 2
        var lines: [[Span]] = snapshot.lines.suffix(room).map { line in
            let style = line.level.map { "EF".contains($0) ? Theme.red : "D".contains($0) ? Theme.faint : Theme.text } ?? Theme.text
            return (line.time.isEmpty ? [] : [Span(String(line.time.suffix(12)) + " ", Theme.faint)]) + [Span(line.text, style)]
        }
        if lines.isEmpty { lines = [[Span(snapshot.ended.map { $0.isEmpty ? "Stopped" : $0 } ?? "Waiting for log messages…", Theme.faint)]] }
        for offset in 0..<room {
            let content = offset < lines.count ? lines[offset].truncated(inner) : []
            output += Box.line(column: panel.column, row: panel.row + 1 + offset, width: width,
                               [Span("│ ", Theme.border)] + content + [Span(String(repeating: " ", count: max(0, inner - content.width)) + " │", Theme.border)])
        }
        output += Box.line(column: panel.column, row: panel.row + panel.rows - 1, width: width, [Span("╰" + String(repeating: "─", count: max(0, width - 2)) + "╯", Theme.border)])
        return output
    }

    fileprivate func drawTools() -> String {
        guard let selectedIndex = tools else { return "" }
        let help = [Span("↑↓", Theme.cyan), Span(" choose ", Theme.faint), Span("⏎", Theme.cyan), Span(" apply ", Theme.faint), Span("esc", Theme.cyan), Span(" close", Theme.faint)]
        return drawPanel(title: phone.isDevice ? "iPhone tools" : "Simulator tools", width: 46, selected: selectedIndex,
                         rows: toolList().map { ([Span($0.name, $0.enabled ? Theme.text : Theme.faint)], [Span($0.detail, $0.enabled ? Theme.muted : Theme.faint)], $0.enabled, .tool($0.tool)) },
                         help: help)
    }
}

// MARK: App Store panel

/// App Store screenshots and app previews from the viewer: the size, frame, background and
/// caption are chosen here (and remembered), and every file lands on the Desktop.
extension PhoneViewer {
    fileprivate enum StudioItem: Equatable { case screenshot, record, size, frame, background, caption, statusBar, reveal }
    fileprivate struct StudioRow { let item: StudioItem; let name: String; let detail: [Span]; let enabled: Bool }

    private var nativeSize: PixelSize { PixelSize(screen.nativeWidth, screen.nativeHeight) }

    fileprivate func studioRows() -> [StudioRow] {
        let s = studioSettings, auto = AppStoreDisplay.auto(for: nativeSize)
        let display = s.chosenDisplay ?? auto
        let shot = display.screenshotSize(for: nativeSize), preview = display.previewSize(landscape: nativeSize.landscape)
        let zoomNote: [Span] = visibleCrop == nil ? [] : [Span("zoomed · ", Theme.accent)]
        func choice(_ text: String, _ style: String = Theme.text) -> [Span] { [Span("‹ ", Theme.faint), Span(text, style), Span(" ›", Theme.faint)] }
        let ours = recordingPlan?.appStore == true, someoneElses = recording != nil && !ours
        var rows = [
            StudioRow(item: .screenshot, name: "Take screenshot",
                      detail: zoomNote + [Span(s.asShown ? "PNG" : "\(shot.width)×\(shot.height) PNG", Theme.muted)], enabled: true),
            StudioRow(item: .record, name: ours ? "Stop and save" : s.asShown ? "Record video" : "Record app preview",
                      detail: ours ? [Span(recordingTime(appStore: !s.asShown), Theme.red)] : someoneElses ? [Span("stop the other recording", Theme.faint)]
                                   : zoomNote + [Span(s.asShown ? (s.background == "transparent" ? "MOV with alpha" : "MP4") : "\(preview.width)×\(preview.height) · 15–30 s", Theme.muted)],
                      enabled: !someoneElses && mediaTask == nil),
            StudioRow(item: .size, name: "Size", detail: choice(s.asShown ? "As shown" : s.chosenDisplay == nil ? "Auto · \(auto.rawValue)\""
                                                                : display.isPad ? "iPad \(display.rawValue.dropFirst(5))\"" : "\(display.rawValue)\""), enabled: true),
            StudioRow(item: .frame, name: "Device frame", detail: s.frame ? choice(finish.displayName) : [Span("Off", Theme.muted)], enabled: true),
            StudioRow(item: .background, name: "Background",
                      detail: choice(s.background.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? (s.frame || s.caption != nil ? "Light (auto)" : "None")), enabled: true),
            StudioRow(item: .caption, name: "Caption",
                      detail: captionDraft.map { [Span($0, Theme.text), Span("▏", Theme.accent)] } ?? [Span(s.caption ?? "None · ⏎ to type", s.caption == nil ? Theme.faint : Theme.text)],
                      enabled: true),
        ]
        if !phone.isDevice {
            rows.append(StudioRow(item: .statusBar, name: "Clean status bar", detail: [Span(statusBarClean == nil ? "…" : statusBarClean! ? "On · 9:41" : "Off", Theme.muted)], enabled: !viewOnly))
        }
        rows.append(StudioRow(item: .reveal, name: "Show in Finder", detail: [Span(lastMedia?.lastPathComponent ?? "nothing saved yet", Theme.faint)], enabled: lastMedia != nil))
        return rows
    }
    private func recordingTime(appStore: Bool) -> String {
        let seconds = Int(Date().timeIntervalSince(recording?.started ?? Date()))
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return appStore ? time + (seconds < 15 ? " · keep going" : seconds > 30 ? " · trims to 30 s" : " · good length") : time
    }

    fileprivate func openStudio() {
        if menu != nil || picker != nil || tools != nil { closeMenu() }
        studio = 0; previousChrome = ""
        loadStatusBar()
    }
    private func loadStatusBar() {
        guard !phone.isDevice else { return }
        let udid = phone.udid
        Task { @MainActor in
            let overrides = (try? await cli.simctl(["status_bar", udid, "list"], timeout: 10)).map { String(decoding: $0, as: UTF8.self) }
            guard udid == phone.udid else { return }
            statusBarClean = overrides.map { $0.contains("9:41") }; previousChrome = ""
        }
    }
    private func saveStudio() {
        guard var config = try? PhoneConfiguration.load(store: cli.store) else { return }
        config.appStore = studioSettings; try? config.save(store: cli.store)
    }

    /// `step` is −1 or +1 for ← and →, and 0 for Return or a click.
    fileprivate func runStudio(_ item: StudioItem, step: Int) {
        guard let row = studioRows().first(where: { $0.item == item }) else { return }
        previousChrome = ""
        switch item {
        case .screenshot: if step == 0 { appStoreScreenshot() }
        case .record:
            guard step == 0 else { return }
            guard row.enabled else { record("Stop the current recording first", ok: false); return }
            recordingPlan?.appStore == true ? stopRecording(wait: false) : startRecording(appStore: true)
        case .size:
            studioSettings.display = AppStoreSettings.step(AppStoreSettings.displays, from: studioSettings.display, by: step == 0 ? 1 : step)
            studioSettings.normalize(); saveStudio()
        case .frame:
            if step == 0 || !studioSettings.frame { studioSettings.frame.toggle() }
            else {
                // ← → try finishes on the live phone too, and the choice is saved for this phone.
                finish = AppStoreSettings.step(FrameFinish.allCases, from: finish, by: step)
                Self.saveFrame(finish, for: phone.name, store: cli.store); relayout()
            }
            saveStudio()
        case .background:
            studioSettings.background = AppStoreSettings.step(AppStoreSettings.backgrounds(asShown: studioSettings.asShown), from: studioSettings.background, by: step == 0 ? 1 : step)
            saveStudio()
        case .caption:
            if step == 0 { captionDraft = studioSettings.caption ?? "" }
        case .statusBar:
            guard step == 0 else { return }
            guard row.enabled else { record("View only — select Enable control first", ok: false); return }
            runTool(.statusBar)
        case .reveal:
            if step == 0, let lastMedia { NSWorkspace.shared.activateFileViewerSelecting([lastMedia]) }
        }
    }
    private func commitCaption() {
        let text = (captionDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        studioSettings.caption = text.isEmpty ? nil : text; captionDraft = nil; previousChrome = ""
        saveStudio()
    }

    private func appStoreScreenshot() {
        capture(studioSettings.style(finish: finish, crop: visibleCrop), kind: "screenshot")
    }
    /// Takes a full-resolution screenshot and saves it composed in `style`, at an App Store size
    /// or the phone's own (cropped to the zoomed view when `style.crop` is set).
    fileprivate func capture(_ style: MediaStyle, kind: String) {
        let name = phone.name
        Task { @MainActor in
            do {
                let (image, scale) = try await cli.nativeScreenshot(name)
                let url: URL, size: PixelSize
                if case .appStore = style.size {
                    let (_, saved) = try cli.writeScreenshot(image, scale: scale, style: style, to: { self.outputURL("App Store \($0.rawValue)", "png") })
                    url = saved.url; size = saved.canvas
                } else {
                    let composer = try MediaComposer(style: style, source: PixelSize(image.width, image.height), scale: scale, canvas: nil)
                    url = outputURL(kind, "png"); size = composer.layout.canvas
                    try MediaComposer.write(try composer.image(image), to: url)
                }
                lastMedia = url; previousChrome = ""
                record("Saved \(url.lastPathComponent) · \(size.width)×\(size.height)", ok: true)
            } catch { record("Screenshot failed: \(error.localizedDescription)", ok: false) }
        }
    }

    fileprivate func drawStudio() -> String {
        guard let selectedIndex = studio else { return "" }
        let rows = studioRows()
        let help: [Span] = captionDraft != nil
            ? [Span("type", Theme.cyan), Span(" caption ", Theme.faint), Span("⏎", Theme.cyan), Span(" save ", Theme.faint), Span("esc", Theme.cyan), Span(" cancel", Theme.faint)]
            : [Span("↑↓", Theme.cyan), Span(" choose ", Theme.faint), Span("←→", Theme.cyan), Span(" change ", Theme.faint), Span("⏎", Theme.cyan), Span(" go ", Theme.faint), Span("esc", Theme.cyan), Span(" close", Theme.faint)]
        return drawPanel(title: "App Store", width: 50, selected: selectedIndex,
                         rows: rows.map { row in
                             let primary = row.item == .screenshot || row.item == .record
                             return ([Span(row.name, !row.enabled ? Theme.faint : primary ? Theme.bold + Theme.text : Theme.text)], row.detail, row.enabled, .studio(row.item))
                         }, help: help, footer: [Span("Files go to the Desktop", Theme.faint)])
    }

    /// A bordered list panel at the top left. Every cell has a background so it covers the phone.
    private func drawPanel(title: String, width preferred: Int, selected: Int, rows: [(left: [Span], right: [Span], enabled: Bool, action: Action)],
                               help: [Span], footer: [Span] = []) -> String {
        guard let layout, !rows.isEmpty else { return "" }
        let surface = Theme.surface, highlight = Theme.selected
        let width = min(layout.columns - 2, preferred)
        let top = layout.roomy ? 4 : 2, extra = footer.isEmpty ? 0 : 1
        let visible = max(1, min(rows.count, layout.rows - top - 3 - extra))
        let first = min(max(0, selected - visible + 1), rows.count - visible)
        let column = 2
        var output = ""
        func paint(_ row: Int, _ spans: [Span], background: String) {
            let fitted = spans.truncated(width)
            output += "\u{1b}[\(row);\(column)H" + fitted.map { Span($0.text, background + $0.style) }.rendered +
                [Span(String(repeating: " ", count: max(0, width - fitted.width)), background)].rendered
        }
        func line(_ content: [Span]) -> [Span] {
            let inner = content.truncated(width - 4)
            return [Span("│ ", Theme.border)] + inner + [Span(String(repeating: " ", count: max(0, width - 3 - inner.width))), Span("│", Theme.border)]
        }
        paint(top, [Span("╭─ ", Theme.border), Span(title, Theme.bold + Theme.accent), Span(" " + String(repeating: "─", count: max(0, width - title.count - 5)) + "╮", Theme.border)], background: surface)
        for (offset, item) in rows[first..<(first + visible)].enumerated() {
            let index = first + offset, row = top + 1 + offset
            let right = item.right.truncated(max(0, width - item.left.width - 6))
            let gap = max(1, width - 4 - item.left.width - right.width)
            paint(row, line(item.left + [Span(String(repeating: " ", count: gap))] + right), background: index == selected ? highlight : surface)
            hits.insert(Hit(row: row, columns: column...(column + width - 1), action: item.action), at: 0)
        }
        if !footer.isEmpty { paint(top + visible + 1, line(footer), background: surface) }
        paint(top + visible + 1 + extra, line(help), background: surface)
        paint(top + visible + 2 + extra, [Span("╰" + String(repeating: "─", count: max(0, width - 2)) + "╯", Theme.border)], background: surface)
        menuArea = (column, top, width, visible + 3 + extra)
        return output
    }
}
