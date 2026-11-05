import Foundation
import TerminalMacCore
import TerminalPhoneCore

enum SplitDirection: String, CaseIterable { case right, left, down, up }

/// Opens the phone viewer in a new pane beside the one the command was run from, so an agent
/// (or you) can show the phone next to its own terminal. Each terminal has its own scripting
/// interface; terminals without one get a new window, or the exact command to run by hand.
enum TerminalSplit {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        /// Failures of a best-effort step (such as switching kitty to its splits layout) are ignored.
        var optional = false
    }
    struct Plan: Equatable {
        let terminal: TerminalApp
        let steps: [Invocation]
        /// Set when the result is not a split, for example a new Terminal window.
        let note: String?
    }
    struct Unsupported: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The shell command a new pane runs. If the viewer fails, the pane stays open to show why.
    static func paneCommand(executable: String, arguments: [String], environment: [String: String]) -> String {
        let exports = ["TERMINAL_PHONE_HOME", "TERMINAL_PHONE_DEPENDENCIES"].compactMap { key in environment[key].map { "\(key)=\(quote($0))" } }
        let viewer = (exports.isEmpty ? [] : ["env"] + exports) + ([executable] + arguments).map(quote)
        return viewer.joined(separator: " ") + " || { printf '\\nPress return to close. '; read _; }"
    }

    /// Works out how to split this terminal. Pure, so every terminal's commands can be tested.
    static func plan(profile: TerminalProfile, environment env: [String: String], direction: SplitDirection,
                     command: String, directory: String, tty: String?, find: (String) -> String?) throws -> Plan {
        let shell = ["/bin/sh", "-c", command]
        let manual = "Split this pane yourself, then run:\n  \(command)"
        if profile.tmux {
            guard let tmux = find("tmux") else { throw Unsupported(message: "tmux is not on PATH. \(manual)") }
            let orientation = direction == .right || direction == .left ? "-h" : "-v"
            let before = direction == .left || direction == .up ? ["-b"] : []
            let pane = env["TMUX_PANE"].map { ["-t", $0] } ?? []
            return Plan(terminal: profile.app, steps: [Invocation(executable: tmux, arguments: ["split-window", orientation] + before + ["-l", "45%", "-c", directory] + pane + ["--"] + shell)], note: nil)
        }
        switch profile.app {
        case .kitty:
            guard let kitty = find("kitty") else { throw Unsupported(message: "kitty's command line tool is not on PATH. \(manual)") }
            guard direction == .right || direction == .down else { throw Unsupported(message: "kitty opens splits to the right or below. Use --split right or --split down.") }
            let to: [String] = env["KITTY_LISTEN_ON"].map { ["--to", $0] } ?? []
            let window = env["KITTY_WINDOW_ID"]
            let match: [String] = window.map { ["--match", "id:\($0)"] } ?? []
            let nextTo: [String] = window.map { ["--next-to", "id:\($0)"] } ?? []
            let location = direction == .right ? "vsplit" : "hsplit"
            var layout: [String] = ["@"] + to
            layout += ["goto-layout"] + match + ["splits"]
            var launch: [String] = ["@"] + to
            launch += ["launch", "--type=window", "--location=\(location)", "--bias=45", "--cwd=\(directory)"]
            launch += nextTo + ["--"] + shell
            // vsplit/hsplit only take effect in the splits layout; switching is best effort.
            return Plan(terminal: .kitty, steps: [Invocation(executable: kitty, arguments: layout, optional: true),
                                                  Invocation(executable: kitty, arguments: launch)], note: nil)
        case .wezterm:
            guard let wezterm = find("wezterm") else { throw Unsupported(message: "wezterm is not on PATH. \(manual)") }
            let flag = ["right": "--right", "left": "--left", "down": "--bottom", "up": "--top"][direction.rawValue]!
            let pane = env["WEZTERM_PANE"].map { ["--pane-id", $0] } ?? []
            return Plan(terminal: .wezterm, steps: [Invocation(executable: wezterm, arguments: ["cli", "split-pane"] + pane + [flag, "--percent", "45", "--cwd", directory, "--"] + shell)], note: nil)
        case .iterm:
            guard direction == .right || direction == .down else { throw Unsupported(message: "iTerm2 opens splits to the right or below. Use --split right or --split down.") }
            guard let session = env["ITERM_SESSION_ID"]?.split(separator: ":").last.map(String.init) else { throw Unsupported(message: "This iTerm2 pane has no session ID. \(manual)") }
            return Plan(terminal: .iterm, steps: [Invocation(executable: "/usr/bin/osascript", arguments: ["-e", itermScript, session, "/bin/sh -c " + quote(command), direction.rawValue])], note: nil)
        case .ghostty:
            if let version = env["TERM_PROGRAM_VERSION"], version.compare("1.3.0", options: .numeric) == .orderedAscending {
                throw Unsupported(message: "Ghostty \(version) can't be scripted; Ghostty 1.3 or newer can. \(manual)")
            }
            let code = ["right": "GSrt", "left": "GSlf", "down": "GSdn", "up": "GSup"][direction.rawValue]!
            return Plan(terminal: .ghostty, steps: [Invocation(executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", ghosttyScript, tty ?? "", directory, code, "/bin/sh -c " + quote(command)])], note: nil)
        case .apple:
            let script = "tell application \"Terminal\"\nactivate\ndo script \(appleString("cd \(quote(directory)) && /bin/sh -c \(quote(command))"))\nend tell"
            return Plan(terminal: .apple, steps: [Invocation(executable: "/usr/bin/osascript", arguments: ["-e", script])], note: "Terminal has no split panes, so the phone opened in a new window.")
        case .alacritty:
            guard let alacritty = find("alacritty") else { throw Unsupported(message: "alacritty is not on PATH. \(manual)") }
            return Plan(terminal: .alacritty, steps: [Invocation(executable: alacritty, arguments: ["msg", "create-window", "--working-directory", directory, "-e"] + shell)],
                        note: "Alacritty has no split panes, so the phone opened in a new window.")
        case .warp:
            throw Unsupported(message: "Warp can't be scripted to split. Press ⌘D to split right, then run:\n  \(command)")
        case .vscode:
            throw Unsupported(message: "VS Code can't be split from the command line. Press ⌘\\ in its terminal, then run:\n  \(command)")
        case .unknown:
            throw Unsupported(message: "terminal-phone can't split this terminal automatically. \(manual)")
        }
    }

    /// Opens the split. Returns what was done, for the caller's JSON.
    @MainActor
    static func open(name: String, direction: SplitDirection, extraArguments: [String] = []) async throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        let tmuxClient = env["TMUX"] != nil ? (try? await CommandRunner.checked(find("tmux") ?? "/usr/bin/false", ["display-message", "-p", "#{client_termname}"], timeout: 5))
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } : nil
        let profile = TerminalProfile.detect(env, tmuxClientTerm: tmuxClient)
        let executable = Bundle.main.executableURL!.resolvingSymlinksInPath().path
        let command = paneCommand(executable: executable, arguments: ["view", name] + extraArguments, environment: env)
        let plan = try plan(profile: profile, environment: env, direction: direction, command: command,
                            directory: FileManager.default.currentDirectoryPath, tty: await callerTTY(), find: find)
        for step in plan.steps {
            let result = try await CommandRunner.run(step.executable, step.arguments, timeout: 20)
            guard result.status == 0 || step.optional else {
                let detail = (result.error.isEmpty ? String(decoding: result.output, as: UTF8.self) : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(failureHint(plan.terminal, detail: String(detail.prefix(600)), command: command))
            }
        }
        var reply: [String: Any] = ["ok": true, "name": name, "terminal": profile.displayName, "split": plan.note == nil ? direction.rawValue : "window"]
        if let note = plan.note { reply["note"] = note }
        return reply
    }

    private static func failureHint(_ terminal: TerminalApp, detail: String, command: String) -> String {
        let fix: String = switch terminal {
        case .kitty: "Enable kitty remote control: add `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` to kitty.conf, then restart kitty."
        case .iterm, .ghostty, .apple: "Allow your terminal to control \(terminal.displayName) in System Settings → Privacy & Security → Automation."
        default: "Check that \(terminal.displayName) is running and scriptable."
        }
        return "Could not open a split in \(terminal.displayName): \(detail.isEmpty ? "no details" : detail)\n\(fix)\nOr split the pane yourself and run:\n  \(command)"
    }

    /// The terminal device of this command or its nearest ancestor that has one. An agent's
    /// shell often has no terminal of its own, but the agent it runs under does.
    private static func callerTTY() async -> String? {
        for descriptor in [0, 1, 2] where isatty(Int32(descriptor)) == 1 {
            if let name = ttyname(Int32(descriptor)) { return String(cString: name) }
        }
        var pid = getppid()
        for _ in 0..<16 where pid > 1 {
            guard let data = try? await CommandRunner.checked("/bin/ps", ["-o", "tty=,ppid=", "-p", String(pid)], timeout: 5) else { return nil }
            let parts = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return nil }
            if !parts[0].hasPrefix("?") { return "/dev/" + parts[0] }
            pid = pid_t(parts[1]) ?? 1
        }
        return nil
    }

    static func find(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        let bundled = ["kitty": "/Applications/kitty.app/Contents/MacOS/kitty", "wezterm": "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                       "alacritty": "/Applications/Alacritty.app/Contents/MacOS/alacritty"]
        let search = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in search.split(separator: ":") {
            let path = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return bundled[name].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    static func quote(_ value: String) -> String {
        value.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func appleString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Splits the iTerm2 session whose ID the shell inherited.
    static let itermScript = """
    on run argv
      set wanted to item 1 of argv
      set startCommand to item 2 of argv
      set place to item 3 of argv
      tell application "iTerm"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if (id of s) is wanted then
                tell s
                  if place is "right" then
                    split vertically with same profile command startCommand
                  else
                    split horizontally with same profile command startCommand
                  end if
                end tell
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
      end tell
      error "This iTerm2 session is no longer open."
    end run
    """

    /// Splits the Ghostty terminal on our TTY (or, failing that, the only one in this directory)
    /// with Ghostty 1.3's Apple Events. Event and class codes as used by pixel (MIT, Zenbu Labs).
    static let ghosttyScript = #"""
    ObjC.import("Foundation");
    function run(argv) {
      const [tty, directory, direction, command] = argv;
      const D = $.NSAppleEventDescriptor;
      const code = (t) => ((t.charCodeAt(0) << 24) | (t.charCodeAt(1) << 16) | (t.charCodeAt(2) << 8) | t.charCodeAt(3)) >>> 0;
      const type = (t) => D.descriptorWithTypeCode(code(t));
      const enumerated = (t) => D.descriptorWithEnumCode(code(t));
      const text = (t) => D.descriptorWithString(t);
      const all = D.descriptorWithDescriptorTypeData(code("abso"), $(" lla").dataUsingEncoding($.NSMacOSRomanStringEncoding));
      function specifier(wanted, from, form, key) {
        const record = D.recordDescriptor;
        record.setDescriptorForKeyword(type(wanted), code("want"));
        record.setDescriptorForKeyword(from, code("from"));
        record.setDescriptorForKeyword(enumerated(form), code("form"));
        record.setDescriptorForKeyword(key, code("seld"));
        return record.coerceToDescriptorType(code("obj "));
      }
      const every = (kind, from) => specifier(kind, from, "indx", all);
      const property = (name, of) => specifier("prop", of, "prop", type(name));
      const ghostty = D.descriptorWithBundleIdentifier("com.mitchellh.ghostty");
      function send(eventClass, eventId, params) {
        const event = D.appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(code(eventClass), code(eventId), ghostty, -1, 0);
        for (const key of Object.keys(params)) event.setParamDescriptorForKeyword(params[key], code(key));
        const failure = Ref();
        const reply = event.sendEventWithOptionsTimeoutError(3, 10, failure);
        if (reply.isNil()) throw new Error("Ghostty did not answer.");
        const number = reply.paramDescriptorForKeyword(code("errn"));
        if (!number.isNil()) throw new Error("Ghostty refused the request (" + number.int32Value + ").");
        return reply.paramDescriptorForKeyword(code("----"));
      }
      function flatten(descriptor, out) {
        if (descriptor.isNil()) { out.push(""); return out; }
        if (descriptor.descriptorType === code("list")) {
          for (let i = 1; i <= descriptor.numberOfItems; i++) flatten(descriptor.descriptorAtIndex(i), out);
          return out;
        }
        const value = descriptor.stringValue;
        out.push(value.isNil() ? "" : ObjC.unwrap(value));
        return out;
      }
      const terminals = every("Gtrm", every("Gtab", every("Gwnd", D.nullDescriptor)));
      const read = (name) => { try { return flatten(send("core", "getd", { "----": property(name, terminals) }), []); } catch (e) { return []; } };
      const ids = read("ID  "), ttys = read("Gtty"), directories = read("Gwdr");
      let index = tty ? ttys.indexOf(tty) : -1;
      if (index < 0) {
        const here = directories.map((d, i) => (d === directory ? i : -1)).filter((i) => i >= 0);
        if (here.length === 1) index = here[0];
      }
      if (index < 0 || !ids[index]) throw new Error("Could not find this pane in Ghostty. Run the command from the pane you want to split.");
      const configuration = D.recordDescriptor;
      configuration.setDescriptorForKeyword(text(directory), code("GScD"));
      configuration.setDescriptorForKeyword(text(command), code("GScC"));
      configuration.setDescriptorForKeyword(D.descriptorWithBoolean(false), code("GScW"));
      send("Ghst", "Splt", { "----": specifier("Gtrm", D.nullDescriptor, "ID  ", text(ids[index])), GSpd: enumerated(direction), GSpS: configuration });
      return "ok";
    }
    """#
}
