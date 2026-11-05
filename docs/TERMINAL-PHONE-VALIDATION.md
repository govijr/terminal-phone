# terminal-phone validation

## 0.2.0 agent runtime — November 2, 2026

The shared agent runtime, simulator/WDA adapters, CLI front end, seven-tool MCP server and private local session transport are implemented. The executable is a local ad-hoc signed build, not a notarized public release.

- Release build and strict ad-hoc signature verification passed; version is **0.2.0**. The package includes the persistent agent helper and `dist/agent/AGENT.md`.
- **51 automated tests passed, 0 failures**, including 17 agent-session tests and five mocked WDA protocol tests. Coverage includes stale/wrong-screen references, ambiguous/disabled targets, input grants, controller conflicts, request deduplication, uncertain input outcomes, postcondition verification, cancellation before dispatch, screenshot retention across restarts, private socket framing, WDA native target bounds, session reuse and bounded invalid-session recovery.
- `scripts/test-phone-agent.py --live` passed **13 protocol/live acceptance checks** on a dedicated iPhone 17 Pro / iOS 26.1 simulator, UUID `D8E738C1-308F-4DB9-BBC1-42F36EEF3328`. CLI and MCP reused one session. Reference taps and postconditions updated the demo counter; duplicate request IDs did not tap twice; fill replaced existing text including a leading-dash literal. MCP returned a real PNG, cancellation stopped polling and prevented queued input, and Stop interrupted a pending wait while leaving the simulator running until explicit shutdown.
- The existing `scripts/test-phone-live.py` passed its **seven legacy checks** against the same dedicated simulator: install/launch, literal typing, Backspace, coordinate taps, screenshot geometry, Home/swipe and shutdown.
- The PTY viewer check passed for **Kitty (4 frames)** and **iTerm (5 frames)**, including resize, decoded canvas dimensions matching the reported 8×21 terminal cells, exit and terminal restoration. Its earlier footer/aspect-flag assumptions were replaced with checks of actual graphics frames and image geometry, matching the existing canvas renderer.
- Python syntax checks and shell syntax checks passed. The test simulator was shut down after validation; its registration/app data were retained. No personal iPhone was controlled.

Reproduce from this workspace after building the included demo app:

```sh
bash scripts/build-phone.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox --cache-path .build/cache \
  --config-path .build/configuration --security-path .build/security
python3 scripts/test-phone-agent.py --live --phone agent-validation \
  --home .build/phone-agent-validation
python3 scripts/test-phone-live.py --phone agent-validation \
  --home .build/phone-agent-validation
```

The viewer script requires its named simulator to be booted. Always stop that dedicated simulator after the check. Test logs/reports from this run are in `.build/phone-agent-tests.log`, `.build/phone-agent-live.json`, `.build/phone-agent-legacy.json` and `.build/phone-agent-viewer.json`.

Remaining acceptance: run the new WDA-backed observation, native element actions, signing renewal, lock/disconnect recovery and ownership handover on physical iPhone hardware. Mocked WDA tests and compilation do not prove hardware acceptance. Exact visual appearance/performance in a real terminal emulator, varied third-party app layouts/languages, and simultaneous independent phones also remain separate checks. Simulator foreground-app bundle identification is intentionally unavailable; use UI-based conditions and inspect capabilities. Captures are sequential, and reference validation cannot eliminate changes between inspection and native input.

## 0.1.1 viewer correction — November 1, 2026

The original inline viewer forced images into a rectangle derived from assumed 8×16 terminal cells, used screenshot polling with a 500 ms delay, and launched an idb CLI process for each input. Mouse-down was treated as a tap and mouse movement was ignored. A user screenshot exposed the resulting distortion and poor responsiveness.

The updated viewer preserves image aspect ratio by specifying a single sizing dimension, queries real cell dimensions, centers the phone, and maps input through that geometry. It streams MJPEG over one persistent local idb connection, targets 20 incoming fps and at most 15 terminal draws per second, drops obsolete frames, and skips identical frames. Input runs independently of drawing, with ordered requests, drag-to-swipe on release, and bounded/coalesced wheel events. Kitty image buffers alternate to avoid deleting the visible frame before its replacement is ready.

Validation on the same dedicated iPhone 17 Pro / iOS 26.1 simulator:

- Release build and ad-hoc signature verification passed. Version reports **0.1.1**.
- **22 automated tests passed**, including regressions for 8×21 cells, centered hit mapping, width-limited layouts, and fragmented terminal size reports.
- Kitty and iTerm protocol checks passed with **zero ioctl pixel dimensions** and simulated cell-size reports, including resize, natural-aspect sizing, exit and restoration.
- The real viewer process was driven through a PTY. Clicks incremented the demo counter, character-by-character typing reached the field and submitted correctly, a mouse drag changed its paging view to page 2, and continuous wheel events scrolled the Settings app. These effects were confirmed through accessibility.
- A local comparison measured **273.1 ms median** for the old CLI-per-tap route (3 samples), **5.7 ms median** for persistent input request/acknowledgement (19 warm samples), and **20.3 incoming video fps** (67 frames). These are local transport/stream measurements, not physical-screen input-to-photon measurements or a guarantee of terminal-emulator draw performance.
- The tests use the explicit validation simulator UUID; the user's `default` phone and running viewer are not restarted by this work.

Manual appearance testing in a native Ghostty window was unavailable because computer-use access to that app was denied. The exact embedded terminal from the user's screenshot remains unverified. Its image can no longer be stretched by the viewer; accurate clicks still require terminal cell-size reporting or the explicit `--cell-size WIDTHxHEIGHT` override.

Reproduce the interactive regression with the validation phone booted:

```sh
python3 scripts/test-phone-responsiveness.py --phone validation --home "$PWD/.build/phone-validation"
```

The results below record the original 0.1.0 validation and its narrower acceptance scope.

Recorded November 1, 2026. This applies to the local 0.1.0 prototype, not a public production release.

## Build and automated checks

- `bash scripts/build-phone.sh`: Release build passed; `dist/terminal-phone` is ad-hoc signed and its signature verifies.
- `swift test`: **20 passed, 0 failed** (14 existing terminal-mac core tests and 6 new phone tests).
- Phone tests cover installed runtime/device compatibility, explicit simulator ownership checks, registry boundaries, literal text argument handling, coordinate validation, subprocess failures, large output without pipe deadlock, and process deadlines.
- `bash examples/PhoneDemo/build.sh`: simulator UIKit app compiled, linked and signed successfully.
- Shell syntax, Python script compilation, and the local idb client's dependency check passed.

## Live simulator and terminal protocol checks

Test environment: Apple silicon, macOS 26.0, Xcode 26.1.1, iOS 26.1 runtime, iPhone 17 Pro. Meta idb client and companion 1.7.8 were used.

The phone was created under a separate test registry at `.build/phone-validation`. The dedicated simulator UUID is `1537FF05-E2FA-4D5C-940D-91B38CBA4ED0`. Existing simulators were not selected for control.

- Creation, background boot and reconnect passed; reconnect keeps the same UUID.
- The included `dev.terminal-phone.demo` app was installed and launched through the CLI.
- Screen capture returned a **402×874 display-point PNG** from a **1206×2622 framebuffer at scale 3**. The captured image was visually inspected.
- UI inspection returned the app's labels, button identifiers and frames.
- `scripts/test-phone-viewer.py` passed for **Kitty and iTerm** output. Each emitted two frames from the live phone, handled a PTY resize from 100×40 to 70×30 cells, exited on Ctrl+], and restored the original terminal attributes and alternate screen.

`scripts/test-phone-live.py` completed successfully on the final build:

- Reconnected twice to the same simulator UUID.
- Installed and launched the demo app.
- Tapped Increment and confirmed the counter increased through accessibility.
- Typed the literal text `--agent-test`, deleted its last character with Backspace, typed it again, submitted it, and confirmed `Message: --agent-test` through accessibility.
- Captured the resulting screen and verified native/display-point dimensions.
- Completed Home and swipe commands against the selected phone, then relaunched the demo.
- Shut down the phone while preserving its registration. The phone was left stopped after testing; its companion exited when it went offline.

The final [demo screenshot](assets/terminal-phone-demo.png) shows the confirmed counter and message. Swipes were checked for successful delivery, not exhaustively tested across app scrolling behavior.

## Fixes found during validation

- idb's default companion can keep a stale HID connection across simulator shutdown/reboot. The CLI now creates a dedicated Unix-socket companion for each phone, with offline and idle termination, and avoids idb's global companion registry.
- idb may explicitly report that an accessibility read should be retried during startup. Only these reads are retried; touch/text actions are not replayed.
- iOS Smart Dashes converted `--agent-test` into `—agent-test`. The demo fixture now disables autocorrection and text substitutions so exact-input assertions are deterministic. Other apps keep their own input behavior.

## Dependency setup on this Mac

The full Homebrew idb metapackage encountered pre-existing linking conflicts while upgrading dependencies. The affected ca-certificates and mpdecimal links were repaired, and the existing Python 3.11 SSL/decimal imports were checked successfully. The native companion was then installed separately through Homebrew, and the matching checksummed client was installed into `dist/dependencies/idb-venv` using the existing Python 3.13.7. The prototype discovers this client automatically. No idb-wide kill/reset was used; only the earlier companion created for the test UUID was stopped and disconnected during cleanup.

## Historical remaining acceptance work (0.1.x)

These items describe the earlier prototype; the 0.2.0 record above supersedes implementation and acceptance status where applicable.

- A human should inspect appearance, click alignment and typing in an actual Ghostty, Kitty or iTerm2 pane. The PTY checks verify protocol framing and terminal restoration, not an emulator's visual rendering or performance.
- Test varied third-party app layouts, text input languages, permissions, orientation changes and concurrent agents on different named phones.
- Project build detection and Android backends are not implemented. Terminal detection, graphics selection and split plans for each terminal are covered by unit tests (`TerminalProfileTests`, `TerminalSplitTests`); splits in each real emulator still need a manual check.
- There is no Developer ID/notarized phone release or hosted installer. Xcode, runtimes and automation dependencies are not bundled for redistribution.

Reproduce the live checks after building both executables and setting up idb:

```sh
python3 scripts/test-phone-live.py --phone validation --home "$PWD/.build/phone-validation"
# test-phone-live stops the phone. Start it again for the viewer check:
TERMINAL_PHONE_HOME="$PWD/.build/phone-validation" ./dist/terminal-phone up validation --no-view
python3 scripts/test-phone-viewer.py --phone validation --home "$PWD/.build/phone-validation"
TERMINAL_PHONE_HOME="$PWD/.build/phone-validation" ./dist/terminal-phone stop validation
```
