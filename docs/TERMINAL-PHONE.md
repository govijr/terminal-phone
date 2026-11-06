# terminal-phone

An interactive iPhone in your terminal, shared with your AI agents. Click and type, drag to swipe, and use the mouse wheel to scroll. Home is always visible.

## Run

After installing, run one command from any folder:

```sh
terminal-phone
```

The CLI finds Xcode, installs a missing iOS simulator runtime, prepares phone controls, boots your phone and opens the interactive viewer. Later runs reuse your phone and configuration. The viewer runs in any terminal. Ghostty and kitty get kitty graphics over shared memory; iTerm2, WezTerm, Warp and VS Code (with `terminal.integrated.enableImages`) get inline images; Terminal.app, Alacritty and unknown terminals get 24-bit or 256-colour half-block graphics. Inside tmux 3.3+ the viewer turns on `allow-passthrough` for its own pane and uses the outer terminal's graphics, with kitty images drawn as Unicode placeholders so tmux keeps them in place. Force a protocol with `--protocol kitty|iterm|blocks`.

To install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/govijr/terminal-phone/main/install.sh | bash
```

The script downloads the release, checks its checksum and runs `terminal-phone self install`. To install a package you downloaded yourself, run `./terminal-phone/terminal-phone self install` from the folder you extracted it into.

Then open a new terminal and run `terminal-phone`. The installer adds the command path, backs up shell configuration before changing it, preserves its file permissions and installs a versioned runtime. It preserves existing phone data and does not package personal iPhone signing files. `--prefix /absolute/path --no-path` supports a custom installation.

Xcode 26 or newer must be installed from Apple and its first-launch/license prompts completed once. The native control runtime requires an Apple silicon Mac with macOS 15 or newer. Everything else is downloaded into a private user cache with pinned archive checksums. Homebrew and an existing Python installation are not required; system Python is unchanged.

## Splits

`terminal-phone up --split right` (or `view NAME --split DIR`, with `right`, `left`, `down` or `up`) opens the viewer in a new pane next to the current one and returns JSON straight away, so it also works from an agent's shell without a TTY.

- tmux: `split-window` beside `$TMUX_PANE`, 45% wide.
- Ghostty 1.3+: a native split through its AppleScript dictionary. macOS asks once for permission to control Ghostty.
- kitty: `kitty @ launch` next to the current window, right or down. Needs `allow_remote_control yes` (or `socket-only` with `listen_on`) in `kitty.conf`.
- iTerm2: a native split of the current session, right or down. macOS asks once for permission to control iTerm2.
- WezTerm: `wezterm cli split-pane`, any direction.
- Terminal.app and Alacritty have no scriptable splits, so the viewer opens in a new window.
- Warp, VS Code and other terminals can't be split from outside; the error includes the exact command to run in a split you open yourself.

If the viewer in the new pane fails, the pane stays open with the error until you press Return.

## Controls

- Click to tap; type normally; drag to swipe; mouse wheel to scroll.
- Home and Lock are in the toolbar. Ctrl+B sends Home; Ctrl+L locks.
- Zoom with − and + in the header. Once zoomed in, the scroll wheel moves around the phone (⌥ + scroll scrolls the app; dragging still swipes), and Screenshot and Record save just what is in view, in the device frame, on a transparent background: a PNG, or a `.mov` with an alpha channel (HEVC) that follows you as you scroll.
- Ctrl+A (or the ✦ App Store button) opens the App Store panel: take a screenshot or record an app preview at App Store Connect's sizes, and pick the size, device frame, background and caption with ←→ and Return. The choices are remembered and files go to the Desktop.
- Ctrl+P switches phones; Ctrl+S saves a screenshot; Ctrl+R toggles recording (simulators and real iPhones). A recording saves a movie and, when you tapped or typed, a `.flow.yaml` beside it that `terminal-phone replay` runs again.
- Ctrl+F or the Frame button opens the frame picker: ↑/↓ or a click previews each finish on the phone, Return keeps it, Esc restores the previous one. `--frame NAME` on `view` or `up` sets it directly: graphite, black, silver, white, gold, orange, red, pink, yellow, green, blue or purple (display names such as "Cosmic Orange" work too). The choice is saved per phone in `configuration.json`.
- Ctrl+T or the Tools button opens the tools panel. On a simulator: clean status bar (9:41), dark mode, larger or smaller text, location (each press moves to the next city: Cupertino, New York, London, Tokyo, Bengaluru, then off), a test notification, and allowing or resetting every permission. The last three act on the app `terminal-phone run` last launched. On a real iPhone: dark or light appearance. ↑/↓ and Return or a click apply a row; Esc closes.
- Ctrl+O or the Logs button opens or closes a logs panel inside the viewer: beside the phone in a wide window, below it in a narrow one. It streams the app `terminal-phone run` last launched, or every process when there isn't one. On a real iPhone it shows the app on screen, which it relaunches to attach to its output. Works in every terminal; for a separate pane, use `terminal-phone logs --split down`.
- Ctrl+] closes the viewer and leaves the phone running.
- View only is an explicit optional mode: `terminal-phone view NAME --read-only`. Its yellow Enable control button restores interaction without restarting.

Your gestures take priority over an agent's inspection/wait. Both use one shared input service, so opening an agent session no longer disables the viewer. A screen that does not change is shown as FPS: idle; it continues to accept input.

## Common commands

```sh
terminal-phone up work                 # another named phone
terminal-phone setup                   # configure/repair the local runtime
terminal-phone setup --check --json    # check readiness without downloads
terminal-phone list
terminal-phone stop work               # keep the phone's data
terminal-phone up work --no-view       # start for an agent without opening a viewer
terminal-phone observe work
terminal-phone act work tap --ref OBSERVATION:e7 --observe
terminal-phone wait work --text 'Welcome' --timeout 10
terminal-phone mcp                     # stdio server launched by an MCP client
```

The last phone selected in the interactive viewer/start flow is remembered. Agent commands accept an explicit phone name. Commands return JSON, send progress to stderr and fail with a nonzero exit status.

## Real iPhones

```sh
terminal-phone connect
```

The connection wizard selects a paired phone, checks Developer Mode, asks the owner whether to allow control and remembers signing configuration. Existing local signing setup is migrated during CLI installation. The owner must unlock the phone and accept Apple's Trust/Developer Mode prompts. If no signing setup exists, the wizard asks once for the development team from Xcode's Accounts settings. These Apple account/security steps cannot be silently completed by the CLI.

For unattended reconnection, use an existing registration. Explicit `--device`, `--team`, `--allow-input`, `--view-only` and `--no-view` options remain available. `terminal-phone device doctor NAME --check` tests the actual WDA observation path. Real devices remain view-only until their owner enables input. Physical-device app installation needs a device-built signed `.app`, while simulators need a simulator `.app`.

To withdraw control, run `terminal-phone device revoke NAME` (or `terminal-phone connect NAME --view-only`). Running sessions re-read the grant on every request, so they become view-only immediately.

> **WebDriverAgent is not authenticated.** terminal-phone enforces view-only itself, but while the WebDriverAgent runner is running on the iPhone it serves an HTTP control API (port 8100) and a video stream (port 9100) without a password. Treat a running runner as an open control session: use it on networks you trust, prefer USB, and run `terminal-phone stop NAME` when you are done. Stopping ends the runner; the iPhone itself keeps running.

## App development and agents

Build the app with your normal Xcode, React Native, Flutter or Expo tools, then install its simulator build on the named phone:

```sh
terminal-phone install work /path/to/Simulator.app
terminal-phone launch work com.example.app
terminal-phone observe work
```

[Agent instructions](TERMINAL-PHONE-AGENT.md) describe element references, verification, recovery and MCP. [Architecture](TERMINAL-PHONE-ARCHITECTURE.md) describes the shared session/input design. [Validation](TERMINAL-PHONE-VALIDATION.md) distinguishes automated, simulator and physical-device checks.

## Build, test and record

### Run your app

In the folder with your `.xcodeproj` or `.xcworkspace`:

```sh
terminal-phone run                       # build, install, launch, then open the viewer
terminal-phone run --watch --split right # keep rebuilding and relaunching on every save
terminal-phone run work --scheme MyApp --configuration Release
```

`run` picks the only workspace or project and the only scheme (or the one named after the project); pass `--workspace`, `--project` or `--scheme` when there are several. Builds go to the phone's own DerivedData, and the full log of the last build is in the phone's folder as `build.log`. A real iPhone needs input permission and your project's signing; `run` passes `-allowProvisioningUpdates`.

### Logs

```sh
terminal-phone logs                      # the app `run` last launched
terminal-phone logs --app com.example.app --level debug
terminal-phone logs --all                # every process on the simulator
terminal-phone logs --split down
```

On a simulator this is `log stream`, filtered to the app's process and subsystem. A real iPhone has no log stream, so `logs` relaunches the app attached to its console: its standard output and error, with iOS asked to mirror `os_log` messages there too.

### Flows

A flow is a list of steps, one per line, in a small YAML subset:

```yaml
# login.flow.yaml
- launch: com.example.app
- tap: "Sign in"                  # an element labelled (or identified) "Sign in"
- fill: {id: email, text: "me@example.com"}
- fill: {label: Password, text: "hunter2"}
- tap: {id: submit}
- expect: "Welcome"               # waits up to --timeout seconds
- expect-not: {text: "Error", timeout: 3}
- scroll: down
- swipe: [200, 600, 200, 200]
- tap: [120, 480]                 # display points
- type: "hello"
- press: return                   # return, backspace, tab, escape, home, lock…
- open: "myapp://settings"
- wait: 1.5
- screenshot: shots/home.png
```

```sh
terminal-phone test login.flow.yaml
terminal-phone test flows/ --phone ci --timeout 20 --junit report.xml
```

Each flow stops at its first failing step, prints why, and saves a screenshot to `terminal-phone-results/` (change it with `--results`). The command prints a JSON summary and exits with status 1 if any flow failed, so it works in CI. Steps that name an element keep retrying until it appears or the timeout passes, so you rarely need `wait`. `tap: "text"` taps the first element, top to bottom, whose label or identifier is that text, or failing that whose label contains it. Start a flow with `launch` so it begins from a known screen: apps such as Settings reopen where you left them.

### Recording and replay

```sh
terminal-phone record                    # until Ctrl+C; saves to the Desktop
terminal-phone record --output demo.gif --duration 20
terminal-phone record --frame --background midnight --output demo.mp4   # in the device frame, on a gradient
terminal-phone replay demo.flow.yaml
```

`record` (and Ctrl+R in the viewer) saves the screen as a movie or GIF and, beside it, a flow of every tap, swipe and keystroke you or an agent sent while it ran, with the pauses between them. Taps from the viewer are recorded as coordinates; an agent's taps on named elements are recorded by identifier or label, which replays more reliably. Text typed into a secure field is never written down.

### App Store screenshots and previews

In the viewer, press Ctrl+A or click ✦ App Store for the same features without typing commands. From the command line:

```sh
terminal-phone sim statusbar clean                  # 9:41, full battery, full signal
terminal-phone appstore screenshot                  # exact size for this phone, e.g. 1206x2622 (6.3")
terminal-phone appstore screenshot --frame --background midnight --caption 'Track every habit'
terminal-phone appstore screenshot --display 6.9    # 1320x2868, whatever phone you use
terminal-phone appstore record --duration 20        # 886x1920 app preview, 30 fps, H.264, silent stereo AAC
terminal-phone appstore record --frame --finish orange --background '#ff7a59,#c2185b' --caption 'See it in motion'
terminal-phone appstore export shot.png --display ipad-13 --frame   # restyle an existing screenshot or recording
terminal-phone appstore sizes                       # every size App Store Connect accepts
```

Output always meets App Store Connect's rules: screenshots are PNG or JPEG at an accepted size with no transparency; app previews are at the accepted preview size (886x1920 for modern iPhones, 1200x1600 for iPads, not the device resolution), constant 30 fps H.264 High Profile 4.0 at about 11 Mbps, with a silent 256 kbps stereo AAC track. Previews longer than 30 s are trimmed, and the JSON result warns when one is shorter than 15 s.

`--display auto` (the default) chooses the display class whose accepted size matches the phone exactly, so a bare screenshot is pixel-for-pixel what the simulator drew. Choosing another class scales the screen to fill it, cropping the few pixels that differ in shape. With `--frame`, `--background` or `--caption`, the phone is fitted inside margins instead, under the caption.

| Option | |
| --- | --- |
| `--display` | `auto`, `6.9`, `6.5`, `6.3`, `6.1`, `5.5`, `4.7`, `ipad-13`, `ipad-11` |
| `--frame`, `--finish COLOUR` | draw the device frame; the colour defaults to the one picked in the viewer (Ctrl+F) |
| `--background` | a preset (`light`, `dark`, `midnight`, `sunset`, `ocean`, `mint`, `grape`, `white`, `black`), a colour such as `'#1e90ff'`, two colours for a top-to-bottom gradient such as `'#0b1d3a,#3a6df0'`, or an image file |
| | `transparent` too, for `record` (a `.mov` with an alpha channel) and the viewer's *As shown* size; App Store Connect rejects transparency, so `appstore` refuses it |
| `--caption`, `--caption-color` | bold text above the phone; `\n` breaks a line. Black or white is chosen to suit the background |
| `--points` | for `export`: the screen's width in points, if the frame looks the wrong size (guessed from the pixels otherwise) |

Landscape screenshots and recordings stay landscape, with the frame turned to match. `record` takes `--frame`, `--finish`, `--background` and `--caption` too, at the phone's own size.

### Action log

```sh
terminal-phone log work --tail 20
terminal-phone log work --follow --json
```

Every input that reached the phone, from the viewer or an agent, is appended to `actions.jsonl` in the phone's folder: time, source, action, the element it targeted, and whether it was delivered. The file is private to your user and rotates at 4 MB. Text typed into secure fields is replaced with `<redacted>` when the target is known; text typed through the viewer is recorded as typed.

### Simulator controls

```sh
terminal-phone sim statusbar clean           # 9:41, full battery and signal; `clear` restores it
terminal-phone sim location 37.3349,-122.0090
terminal-phone sim push com.example.app --text 'Your order shipped' --title 'Orders'
terminal-phone sim push com.example.app payload.json
terminal-phone sim permission grant photos com.example.app
terminal-phone sim text-size accessibility-large
terminal-phone sim appearance dark           # also works on a real iPhone with input allowed
terminal-phone clipboard push 'some text'    # or the Mac's clipboard when no text is given
terminal-phone clipboard pull                # the phone's clipboard to the Mac's
terminal-phone action screenshot --framed --output shot.png
```

`--framed` draws the device frame (in the phone's chosen finish) around a full-resolution screenshot, with transparent corners.

### Locked iPhones

iOS stops screen capture and input while an iPhone is locked, and a locked phone on Wi-Fi often drops its connection. The viewer shows **locked** or **waiting for iPhone**, refuses input meanwhile, and carries on by itself once the phone is unlocked. Keep Auto-Lock long (Settings → Display & Brightness) while you work, or use a simulator.

## Source builds and packages

```sh
bash scripts/build-phone.sh
./dist/terminal-phone self install
bash scripts/release-phone.sh
```

The local package includes the CLI, worker resources, agent guide and license. It excludes dependency caches and personal signing artifacts. `bash scripts/release-phone.sh --signed` signs it with a Developer ID and notarizes it for public download (set `SIGN_IDENTITY` and `NOTARY_PROFILE`). `bash scripts/export-phone-repo.sh --repo OWNER/NAME DIR` assembles the standalone open-source repository and refuses to finish if personal signing or device data would be published.

Registrations and configuration live under `~/Library/Application Support/terminal-phone`; `TERMINAL_PHONE_HOME` selects another registry. Runtime downloads are cached once per user under its `dependencies` directory; `TERMINAL_PHONE_DEPENDENCIES` overrides that cache. No erase/delete command is provided. Simulators share the host Mac's resources; they are not isolated macOS virtual machines. Android remains unsupported.
