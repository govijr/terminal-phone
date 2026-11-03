import AppKit
import Darwin
import TerminalMacCore
import TerminalPhoneCore

@MainActor
final class PhoneViewer {
    static var supportsCurrentTerminal: Bool {
        let e = ProcessInfo.processInfo.environment
        return isatty(0) == 1 && isatty(1) == 1 && e["TMUX"] == nil &&
            (e["TERM_PROGRAM"] == "iTerm.app" || e["TERM_PROGRAM"] == "ghostty" || e["KITTY_WINDOW_ID"] != nil || e["TERM"]?.contains("kitty") == true)
    }
    private enum Link: Equatable { case connecting(String), live, polling }
    private enum Action: Equatable { case menu, select(String), zoomOut, zoomFit, zoomActual, zoomIn, home, lock, screenshot, record, appearance, control }
    private struct Hit { let row: Int; let columns: ClosedRange<Int>; let action: Action }
    private struct Layout: Equatable {
        let viewport: PhoneViewport
        let columns: Int, rows: Int
        /// Roomy panes get a two-line header, a divider and a pill toolbar; small ones one line each.
        let roomy: Bool
    }
    private struct Activity { let at: Date; let text: String; let ok: Bool; let milliseconds: Double? }
    private struct MenuItem { let name: String; let detail: String; let state: String }

    let cli: PhoneCLI, graphics: String
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
    private var recording: (process: Process, url: URL, started: Date)?
    private var dark: Bool?

    init(cli: PhoneCLI, phone: Phone, screen: PhoneScreen, graphics: String?, readOnly: Bool, cellSize: String? = nil) throws {
        self.cli = cli; self.phone = phone; self.screen = screen; self.viewOnly = readOnly
        let e = ProcessInfo.processInfo.environment
        let detected = e["TERM_PROGRAM"] == "iTerm.app" ? "iterm" :
            (e["KITTY_WINDOW_ID"] != nil || e["TERM"]?.contains("kitty") == true || e["TERM_PROGRAM"] == "ghostty") ? "kitty" : nil
        guard let selected = graphics ?? detected, ["kitty", "iterm"].contains(selected) else { throw Failure("Inline view needs Ghostty, Kitty or iTerm2, or --protocol kitty|iterm") }
        guard isatty(0) == 1, isatty(1) == 1 else { throw Failure("view needs an interactive terminal") }
        guard e["TMUX"] == nil else { throw Failure("Run view outside tmux; graphics passthrough is not implemented") }
        if let value = cellSize ?? e["TERMINAL_PHONE_CELL_SIZE"] {
            let p = value.lowercased().split(separator: "x").compactMap { Double($0) }
            guard p.count == 2, p.allSatisfy({ $0.isFinite && (1...256).contains($0) }) else { throw Failure("--cell-size must be WIDTHxHEIGHT in terminal pixels, for example 9x24") }
            cellOverride = (p[0], p[1])
        } else { cellOverride = nil }
        self.graphics = selected
        // Kitty-protocol terminals start on PNG until they confirm shared memory support.
        renderer = PhoneRenderer(writer: writer, transport: selected == "iterm" ? .iterm : .kittyDirect)
    }

    func run() async throws {
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
        var probe = graphics == "kitty" ? PhoneRenderer.sharedMemoryProbe() : nil
        if let probe { writer.write(probe.query) }
        var transportDecided = probe == nil
        defer {
            renderer.configure(placement: nil)
            live?.stop(); polling?.cancel(); switching?.cancel()
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
            if !transportDecided, metrics.graphicsReplies[31] != nil || Date().timeIntervalSince(started) > 0.4 {
                transportDecided = true
                if metrics.graphicsReplies[31] == "OK" { renderer.configure(placement: placement, transport: .kittySharedMemory) }
                probe?.cleanup(); probe = nil
                renderer.redraw()
            }
            // Wait briefly for real cell metrics so the first stream is requested at the right size.
            let settled = metrics.cellHeight != nil || cellOverride != nil || Date().timeIntervalSince(started) > 0.4
            if transportDecided, settled, live == nil, polling == nil, switching == nil {
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
        min(1, max(0.25, (viewport.frame.screenHeight * viewport.scale / Double(screen.nativeHeight) * 8).rounded(.up) / 8))
    }
    /// Restarts the stream when the phone grows past the streamed resolution, or shrinks far below it.
    private func rescaleStreamIfNeeded() {
        guard let layout, liveReady else { return }
        let wanted = streamScale(for: layout.viewport)
        guard wanted > streamScale + 0.01 || wanted < streamScale - 0.26 else { pendingScale = nil; return }
        if pendingScale?.value != wanted { pendingScale = (wanted, Date()); return }
        guard let pending = pendingScale, Date().timeIntervalSince(pending.since) > 0.6, inFlight == nil else { return }
        pendingScale = nil
        live?.stop(); live = nil
        startStream()
    }

    // MARK: Layout

    private var placement: FramePlacement? {
        layout.map { FramePlacement(viewport: $0.viewport, background: graphics == "iterm" ? (metrics.background ?? 0x1e1e1e) : nil) }
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
        let viewport = PhoneViewport(frame: DeviceFrame(screenWidth: screen.width, screenHeight: screen.height),
                                     column: 1, row: top, columns: cols, rows: max(1, bottom - top + 1),
                                     cellWidth: cw * metrics.cellScale, cellHeight: ch * metrics.cellScale, zoom: zoom, pan: pan)
        let next = Layout(viewport: viewport, columns: cols, rows: rows, roomy: roomy)
        guard clear || next != layout else { return }
        let resized = next.columns != layout?.columns || next.rows != layout?.rows || next.roomy != layout?.roomy
        layout = next
        if clear || resized { writer.write("\u{1b}[0m\u{1b}[2J"); previousChrome = ""; menuArea = nil }
        else if graphics == "iterm" { eraseScreenText() }
        renderer.configure(placement: placement)
        drawChrome()
        renderer.redraw()
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
        record("zoom \(Int((zoom * 100).rounded()))%", ok: true)
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
        func icon(_ glyph: String, _ action: Action, style: String = Theme.text) -> ([Span], Action?) {
            ([Span(" \(glyph) ", pressed(action) ? Theme.key : style)], action)
        }

        // Header: "terminal-phone · default ⌄" opens the device menu; FPS and zoom on the right.
        let title: [Span] = [Span(" terminal-phone", Theme.bold + Theme.text), Span(" · ", Theme.faint),
                             Span(phone.name, Theme.bold + Theme.accent), Span(" ⌄", menu != nil ? Theme.accent : Theme.muted)]
        let rate: [Span] = switch link {
        case .connecting: [Span("\(spin) connecting", Theme.yellow)]
        case .polling: [Span("FPS: ", Theme.muted), Span("screenshots", Theme.cyan)]
        case .live: [Span("FPS: ", Theme.muted), fps >= 0.5 ? Span("\(Int(fps.rounded()))", fps >= 20 ? Theme.green : Theme.yellow) : Span("idle", Theme.text)]
        }
        let zoomText = abs(zoom - 1) < 0.01 ? [] : [Span("  \(Int((zoom * 100).rounded()))%", Theme.faint)]
        var right: [([Span], Action?)] = [(rate + zoomText + [Span("  ")], nil)]
        let zoomButtons = [icon("⊖", .zoomOut), ([Span("│", Theme.border)], nil), icon("⊡", .zoomFit), ([Span("│", Theme.border)], nil),
                           icon("①", .zoomActual), ([Span("│", Theme.border)], nil), icon("⊕", .zoomIn), ([Span(" ")], nil)]
        if title.width + 2 + right.reduce(0, { $0 + $1.0.width }) + zoomButtons.reduce(0, { $0 + $1.0.width }) <= cols { right += zoomButtons }
        else if title.width + 2 + right.reduce(0, { $0 + $1.0.width }) > cols { right = [] }
        row(1, left: [(title, .menu)], right: right)
        if layout.roomy {
            let subtitle = [Span("  \(phone.displaySystem)", Theme.muted), Span(" · \(phone.displayModel)\(phone.isDevice ? " · real iPhone" : "")", Theme.faint),
                            Span(readOnly ? " · View only" : " · Interactive", readOnly ? Theme.yellow : Theme.green)]
            row(2, left: [(subtitle, .menu)], right: [(statusLine(now: now, room: cols - subtitle.width - 4), nil)])
            output += "\u{1b}[3;1H" + [Span(String(repeating: "─", count: cols), Theme.border)].rendered
        }

        // Status text drawn on the black screen until video arrives.
        let screenCells = v.screenCells
        let splashRow = screenCells.row + screenCells.rows / 2 - 1
        if stats.frames == 0 || switching != nil {
            let message: String = switch link {
            case .connecting(let text): text
            case .polling: "Waiting for a screenshot"
            case .live: "Waiting for the first frame"
            }
            let lines: [[Span]] = [[Span(spin, Theme.accent)], [Span(message, Theme.text)], [Span(phone.name, Theme.faint)]]
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
        groups.append([("⌂", "Home", .home, readOnly ? Theme.muted : Theme.text), ("⏻", "Lock", .lock, readOnly ? Theme.muted : Theme.text)])
        groups.append([(readOnly ? "▶" : "●", readOnly ? "Enable control" : "Control on", .control, readOnly ? Theme.yellow : Theme.green)])
        // Recording uses simctl, so real iPhones get screenshots only.
        groups.append([("◎", "Screenshot", .screenshot, Theme.text)] + (phone.isDevice ? [] : [(recording == nil ? "●" : "■", recordLabel, .record, recording == nil ? Theme.text : Theme.red)]))
        if dark != nil && !readOnly { groups.append([(dark == true ? "◑" : "◐", dark == true ? "Light" : "Dark", .appearance, Theme.text)]) }
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

        if let menu { output += drawMenu(menu) }

        guard output != previousChrome else { return }
        previousChrome = output
        writer.write(output)
    }

    /// The latest action result, or shortcut hints.
    private func statusLine(now: Date, room: Int) -> [Span] {
        if let last = activity.last, now.timeIntervalSince(last.at) < (last.ok ? 2.5 : 6) {
            let toast = [Span(last.ok ? "✓ " : "✕ ", last.ok ? Theme.green : Theme.red), Span(last.text, last.ok ? Theme.text : Theme.red)] +
                (last.milliseconds.map { [Span(" · \(Int($0.rounded())) ms", Theme.faint)] } ?? []) + [Span(" ")]
            return toast.truncated(max(0, room))
        }
        let hints: [Span] = [Span("⌃P", Theme.cyan), Span(" devices  ", Theme.faint), Span("⌃S", Theme.cyan), Span(" screenshot  ", Theme.faint),
                             Span("⌃]", Theme.cyan), Span(" quit ", Theme.faint)]
        return hints.width <= room ? hints : Array(hints.suffix(2)).width <= room ? Array(hints.suffix(2)) : []
    }

    /// A dropdown of registered phones under the title. Every cell has a background so it covers the phone image.
    private func drawMenu(_ items: [MenuItem]) -> String {
        guard let layout else { return "" }
        let surface = Theme.bg(0x1f2335), selected = Theme.bg(0x2f3549)
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
            let state = ["Booted", "Connected"].contains(item.state) ? Span("● ", Theme.green) : Span("○ ", Theme.faint)
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

    private func record(_ text: String, ok: Bool, milliseconds: Double? = nil) {
        activity.append(Activity(at: Date(), text: text, ok: ok, milliseconds: milliseconds))
        if activity.count > 50 { activity.removeFirst(activity.count - 50) }
    }

    // MARK: Actions

    private func perform(_ action: Action) {
        flash = (action, Date())
        switch action {
        case .menu: menu == nil ? openMenu() : closeMenu()
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
        guard menu != nil else { return }
        menu = nil
        if let area = menuArea {
            // Default-background spaces let the phone image show through again.
            writer.write((area.row..<(area.row + area.height)).map { "\u{1b}[\($0);\(area.column)H\u{1b}[0m" + String(repeating: " ", count: area.width) }.joined())
        }
        menuArea = nil; previousChrome = ""
        if graphics == "iterm" { renderer.redraw() }
    }

    /// Boots the chosen phone if needed and moves the stream to it. The previous phone keeps running.
    private func switchPhone(to name: String) {
        guard name != phone.name, switching == nil else { return }
        stopRecording(wait: false)
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
    private func startRecording() {
        guard !phone.isDevice else { return }
        let url = outputURL("recording", "mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli.xcrun)
        process.arguments = ["simctl", "io", phone.udid, "recordVideo", "--codec=h264", "--force", url.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); recording = (process, url, Date()); record("recording…", ok: true) }
        catch { record("Recording failed: \(error.localizedDescription)", ok: false) }
    }
    /// simctl finishes writing the movie when interrupted.
    private func stopRecording(wait: Bool) {
        guard let current = recording else { return }
        recording = nil
        current.process.interrupt()
        if wait {
            let deadline = Date().addingTimeInterval(5)
            while current.process.isRunning && Date() < deadline { usleep(20_000) }
        } else { record("saved \(current.url.lastPathComponent)", ok: true) }
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
            if menu != nil { closeMenu(); pressedChrome = true; return }
        }
        if pressedChrome { if released { pressedChrome = false }; return }
        let viewport = layout.viewport
        if wheel {
            // Shift+wheel and sideways wheels pan a zoomed phone; a plain wheel scrolls the app.
            let horizontal = button & 3 >= 2
            if horizontal || (shift && (viewport.overflowsX || viewport.overflowsY)) {
                let step = (button & 1 == 0 ? -0.08 : 0.08)
                if horizontal || (shift && !viewport.overflowsY) { pan.x = min(1, max(0, pan.x + step)) } else { pan.y = min(1, max(0, pan.y + step)) }
                relayout(); return
            }
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
