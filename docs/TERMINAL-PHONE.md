# terminal-phone

An interactive iPhone in your terminal, shared with your AI agents. Click and type, drag to swipe, and use the mouse wheel to scroll. Home is always visible.

## Run

After installing, run one command from any folder:

```sh
terminal-phone
```

The CLI finds Xcode, installs a missing iOS simulator runtime, prepares phone controls, boots your phone and opens the interactive viewer. Later runs reuse your phone and configuration. Use Ghostty, Kitty, iTerm2 or a compatible embedded terminal for inline viewing. In other terminals, the CLI returns the running phone's status and agent commands remain available.

To install a downloaded package once:

```sh
./terminal-phone self install
```

Then open a new terminal and run `terminal-phone`. The installer adds the command path, backs up shell configuration before changing it, preserves its file permissions and installs a versioned runtime. It preserves existing phone data and does not package personal iPhone signing files. `--prefix /absolute/path --no-path` supports a custom installation.

Xcode 26 or newer must be installed from Apple and its first-launch/license prompts completed once. The native control runtime requires an Apple silicon Mac with macOS 15 or newer. Everything else is downloaded into a private user cache with pinned archive checksums. Homebrew and an existing Python installation are not required; system Python is unchanged.

## Controls

- Click to tap; type normally; drag to swipe; mouse wheel to scroll.
- Home and Lock are in the toolbar. Ctrl+B sends Home; Ctrl+L locks.
- Ctrl+P switches phones; Ctrl+S saves a screenshot; Ctrl+R toggles recording on simulators.
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

## App development and agents

Build the app with your normal Xcode, React Native, Flutter or Expo tools, then install its simulator build on the named phone:

```sh
terminal-phone install work /path/to/Simulator.app
terminal-phone launch work com.example.app
terminal-phone observe work
```

[Agent instructions](TERMINAL-PHONE-AGENT.md) describe element references, verification, recovery and MCP. [Architecture](TERMINAL-PHONE-ARCHITECTURE.md) describes the shared session/input design. [Validation](TERMINAL-PHONE-VALIDATION.md) distinguishes automated, simulator and physical-device checks.

## Source builds and packages

```sh
bash scripts/build-phone.sh
./dist/terminal-phone self install
bash scripts/release-phone.sh
```

The local package includes the CLI, worker resources, agent guide and license. It excludes dependency caches and personal signing artifacts. `bash scripts/release-phone.sh --signed` signs it with a Developer ID and notarizes it for public download (set `SIGN_IDENTITY` and `NOTARY_PROFILE`). `bash scripts/export-phone-repo.sh --repo OWNER/NAME DIR` assembles the standalone open-source repository and refuses to finish if personal signing or device data would be published.

Registrations and configuration live under `~/Library/Application Support/terminal-phone`; `TERMINAL_PHONE_HOME` selects another registry. Runtime downloads are cached once per user under its `dependencies` directory; `TERMINAL_PHONE_DEPENDENCIES` overrides that cache. No erase/delete command is provided. Simulators share the host Mac's resources; they are not isolated macOS virtual machines. Android, automatic terminal splits and tmux graphics transport remain unsupported.
