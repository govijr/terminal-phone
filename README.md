# terminal-phone


[![](https://img.shields.io/static/v1?label=Sponsor&message=%E2%9D%A4&logo=GitHub&color=%23fe8e86)](https://github.com/sponsors/govijr)
<a href="https://buymeacoffee.com/govijr" target="_blank"><img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" alt="Buy Me A Coffee" style="height: 21px !important;width: 108px !important;box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;-webkit-box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;" ></a>


**An interactive iPhone in your terminal, shared with your AI agents.**

terminal-phone puts an iOS simulator, or your own paired iPhone, inline in your terminal: sharp images in Ghostty, kitty, iTerm2, WezTerm, Warp and VS Code, text graphics everywhere else, and a native split beside your shell. You click, type, drag and scroll on it like a real phone. Your coding agent drives the same phone through a JSON CLI or an MCP server, with element references, postcondition checks and safe recovery, so it can build your app, install it, tap through it and verify the result.

<!-- Add a demo GIF here: docs/assets/demo.gif -->

- **Sharp and fast:** a 30 fps stream sized to your pane's real pixels, drawn through terminal shared memory instead of base64 over the pty.
- **Feels like a phone:** an iPhone frame in twelve finishes (Silver, Space Black, Cosmic Orange, Deep Blue, Red and more), a device switcher, zoom, and Home, Lock, Screenshot, Record and Dark mode controls.
- **Built for agents:** `observe`, `act`, `wait` and an MCP server. Agents get accessibility elements in display points, references that reject stale screens, and receipts that never replay uncertain input.
- **Real iPhones too:** through [WebDriverAgent](https://github.com/appium/WebDriverAgent) over USB or Wi-Fi. They stay view-only until you, the owner, allow control.

## Install

Requirements: an Apple silicon Mac with macOS 15 or later, and Xcode 26 or later installed from Apple and opened once.

**Prebuilt download:** from [Releases](https://github.com/govijr/terminal-phone/releases), with `curl` so macOS doesn't quarantine it:

```sh
base=https://github.com/govijr/terminal-phone/releases/download/v0.3.0
curl -fsSLO "$base/terminal-phone-0.3.0-macos-arm64.tar.gz" -O "$base/terminal-phone-0.3.0-macos-arm64.tar.gz.sha256"
shasum -a 256 -c terminal-phone-0.3.0-macos-arm64.tar.gz.sha256
tar -xzf terminal-phone-0.3.0-macos-arm64.tar.gz
./terminal-phone/terminal-phone self install
```

Release binaries are built from this repository by GitHub Actions and aren't Developer ID signed. If you downloaded with a browser instead, run `xattr -dr com.apple.quarantine terminal-phone` before installing, or build from source.

**From source:**

```sh
git clone https://github.com/govijr/terminal-phone.git && cd terminal-phone
bash scripts/build-phone.sh
./dist/terminal-phone self install
```

## Use it

```sh
terminal-phone
```

The first run finds Xcode, downloads a missing iOS simulator runtime, sets up a private, checksum-verified control runtime (no Homebrew Python or system changes), boots a dedicated simulator and opens it in your terminal.

Click to tap, type normally, drag to swipe, and use the wheel to scroll. Ctrl+P switches phones, Ctrl+S takes a screenshot, Ctrl+B goes Home, Ctrl+F opens the frame picker, Ctrl+T opens the simulator tools (status bar, dark mode, text size, location, notifications, permissions), Ctrl+O shows the app's logs in a panel beside the phone, and Ctrl+] exits while the phone keeps running.

In the frame picker (Ctrl+F or the **Frame** button), the arrow keys or a click try each colour live on the phone, Return keeps it and Esc goes back. You can also set it from the command line with `--frame`, for example `terminal-phone view --frame orange`. The choice is remembered for each phone. The finishes are graphite (the default), black, silver, white, gold, orange, red, pink, yellow, green, blue and purple.

### Terminals and splits

The viewer works in every major macOS terminal and picks the sharpest graphics each one supports. `--split right|left|down|up` opens it in a new pane beside your shell (or your agent) and returns at once, so you can keep working next to the phone:

```sh
terminal-phone up --split right
terminal-phone view work --split down
```

| Terminal | Phone graphics | `--split` |
|---|---|---|
| Ghostty | Sharp (kitty graphics, shared memory) | Native split, Ghostty 1.3+ |
| kitty | Sharp (kitty graphics, shared memory) | Native split, right or down; needs `allow_remote_control yes` |
| iTerm2 | Sharp (inline images) | Native split, right or down |
| WezTerm | Sharp (inline images) | Native split, any direction |
| Warp | Sharp (inline images) | Not scriptable; run the printed command in a split |
| VS Code, Cursor | Sharp with `terminal.integrated.enableImages`, otherwise text | Not scriptable; run the printed command in a split |
| tmux 3.3+ | Inherits the outer terminal's graphics | `split-window` beside the current pane |
| Terminal.app, Alacritty | Text graphics (half blocks) | Opens a new window |

The palette follows your terminal's light or dark background, uses 256 colours where truecolor isn't available, and respects `NO_COLOR`. Force a protocol with `--protocol kitty|iterm|blocks`.

### Build, test and record

```sh
terminal-phone run --watch --split right          # build this folder's Xcode app, launch it, rebuild on save
terminal-phone logs --split down                   # the app's logs beside the phone
terminal-phone record --output demo.gif           # video plus a replayable flow of every tap and keystroke
terminal-phone appstore screenshot --frame --caption 'Track every habit'   # App Store Connect-ready sizes
terminal-phone appstore record --duration 20      # an app preview: 886x1920, 30 fps, audio track included
terminal-phone test flows/ --junit report.xml     # run flow files, for example in CI
```

A flow is a short YAML list of steps:

```yaml
- launch: com.example.app
- tap: "Sign in"
- fill: {id: email, text: "me@example.com"}
- expect: "Welcome"
```

`terminal-phone sim` sets the status bar to 9:41, the location, permissions, text size and appearance, and sends push notifications; `clipboard push|pull` shares the clipboard; `action screenshot --framed` draws the device frame around a screenshot; `appstore screenshot|record|export` makes screenshots and app previews at the exact sizes App Store Connect accepts, with an optional device frame, background and caption; `log` lists every input you or an agent sent. See the [user guide](docs/TERMINAL-PHONE.md#build-test-and-record).

### With your AI agent (MCP)

```sh
claude mcp add terminal-phone -- terminal-phone mcp
```

Any MCP client works: run `terminal-phone mcp` as a stdio server. Agents get `phone_devices`, `phone_boot`, `phone_session`, `phone_capabilities`, `phone_observe`, `phone_act` and `phone_wait`. Without MCP, the same operations are JSON CLI commands:

```sh
terminal-phone up work --no-view
terminal-phone install work /path/to/MyApp.app
terminal-phone launch work com.example.MyApp
terminal-phone observe work
terminal-phone act work tap --id signIn --wait-text 'Welcome' --timeout 10
```

See the [agent guide](docs/TERMINAL-PHONE-AGENT.md) for references, verification and recovery.

### Real iPhone

```sh
terminal-phone connect
```

The wizard picks a paired iPhone, checks Developer Mode, builds and signs WebDriverAgent with your Apple Developer team, and asks you whether agents may control the phone.

> **Real-device control acts on your real accounts and data.** Phones are view-only unless you approve input, and `terminal-phone device revoke NAME` takes it back. Agents and MCP tools can't grant it themselves, and nothing gets past your passcode. The on-phone WebDriverAgent helper has no password of its own, so run `terminal-phone stop NAME` when you're done; see [SECURITY.md](SECURITY.md).

## Documentation

- [User guide](docs/TERMINAL-PHONE.md)
- [Agent guide](docs/TERMINAL-PHONE-AGENT.md)
- [Architecture](docs/TERMINAL-PHONE-ARCHITECTURE.md)
- [Validation](docs/TERMINAL-PHONE-VALIDATION.md)

## Contributing and security

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). terminal-phone downloads third-party components at setup time under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).


## Sponsor

terminal-phone is free and maintained in my own time. [Sponsoring](https://github.com/sponsors/govijr) keeps it that way.
