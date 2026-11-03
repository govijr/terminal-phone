# terminal-phone

**An interactive iPhone in your terminal, shared with your AI agents.**

terminal-phone puts an iOS simulator, or your own paired iPhone, inline in Ghostty, Kitty or iTerm2. You click, type, drag and scroll on it like a real phone. Your coding agent drives the same phone through a JSON CLI or an MCP server, with element references, postcondition checks and safe recovery, so it can build your app, install it, tap through it and verify the result.

<!-- Add a demo GIF here: docs/assets/demo.gif -->

- **Sharp and fast:** a 30 fps stream sized to your pane's real pixels, drawn through terminal shared memory instead of base64 over the pty.
- **Feels like a phone:** an iPhone frame, a device switcher, zoom, and Home, Lock, Screenshot, Record and Dark mode controls.
- **Built for agents:** `observe`, `act`, `wait` and an MCP server. Agents get accessibility elements in display points, references that reject stale screens, and receipts that never replay uncertain input.
- **Real iPhones too:** through [WebDriverAgent](https://github.com/appium/WebDriverAgent) over USB or Wi-Fi. They stay view-only until you, the owner, allow control.

## Install

Requirements: an Apple silicon Mac with macOS 15 or later, and Xcode 26 or later installed from Apple and opened once.

**Homebrew (builds from source):**

```sh
brew install govijr/tap/terminal-phone
```

**Prebuilt download:** from [Releases](https://github.com/govijr/terminal-phone/releases), with `curl` so macOS doesn't quarantine it:

```sh
base=https://github.com/govijr/terminal-phone/releases/download/v0.3.0
curl -fsSLO "$base/terminal-phone-0.3.0-macos-arm64.tar.gz" -O "$base/terminal-phone-0.3.0-macos-arm64.tar.gz.sha256"
shasum -a 256 -c terminal-phone-0.3.0-macos-arm64.tar.gz.sha256
tar -xzf terminal-phone-0.3.0-macos-arm64.tar.gz
./terminal-phone/terminal-phone self install
```

Release binaries are built from this repository by GitHub Actions and aren't Developer ID signed. If you downloaded with a browser instead, run `xattr -dr com.apple.quarantine terminal-phone` before installing, or use Homebrew or a source build.

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

Click to tap, type normally, drag to swipe, and use the wheel to scroll. Ctrl+P switches phones, Ctrl+S takes a screenshot, Ctrl+B goes Home, and Ctrl+] exits while the phone keeps running.

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

> **Real-device control acts on your real accounts and data.** Phones are view-only unless you approve input. Agents and MCP tools can't grant it themselves, and nothing gets past your passcode.

## Documentation

- [User guide](docs/TERMINAL-PHONE.md)
- [Agent guide](docs/TERMINAL-PHONE-AGENT.md)
- [Architecture](docs/TERMINAL-PHONE-ARCHITECTURE.md)
- [Validation](docs/TERMINAL-PHONE-VALIDATION.md)

## Contributing and security

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). terminal-phone downloads third-party components at setup time under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
