# Contributing

Thanks for helping! Bug reports, docs fixes and pull requests are all welcome.

## Develop

You need an Apple silicon Mac, macOS 15 or later, and Xcode 26 or later.

```sh
swift build --product terminal-phone
swift test
bash scripts/build-phone.sh          # release build into dist/, with its worker resources
./dist/terminal-phone
```

`swift test` uses fake backends and never touches a phone. The live checks drive a dedicated simulator and the bundled demo app:

```sh
bash examples/PhoneDemo/build.sh
python3 scripts/test-phone-agent.py --help
```

Run live checks against a dedicated phone name (for example `validation`), never your personal phone.

## Layout

| Path | What it is |
|---|---|
| `Sources/TerminalPhoneCore` | Request/reply types, the `PhoneBackend` protocol, sessions, accessibility normalization, installer |
| `Sources/TerminalPhone` | The CLI, terminal viewer and renderer, idb and WebDriverAgent backends, MCP server |
| `Sources/TerminalUI` | Terminal styling, metrics and the serialized output writer |
| `Sources/TerminalMacCore` | Small shared utilities (arguments, file locks, terminal input parsing) |
| `Sources/CPhoneShim` | C shim for POSIX shared memory (Swift can't call variadic `shm_open`) |
| `resources/` | Python workers for the idb video stream and agent input, and hash-pinned requirements |

[Architecture](docs/TERMINAL-PHONE-ARCHITECTURE.md) explains how to add a backend.

## Pull requests

- Keep changes focused, and add tests for behaviour changes.
- `swift test` must pass. CI runs it on every pull request.
- Anything that sends input to a real device must keep the owner's grant check and must never retry input automatically.
- Don't commit personal data: device identifiers, team IDs, provisioning profiles or screenshots of your phone.
- New downloads must be pinned by SHA-256.

## Releasing (maintainers)

1. Bump `PhoneAgentAPI.productVersion` and tag `vX.Y.Z`. The release workflow tests, builds and attaches the archive.
2. Update `homebrew/terminal-phone.rb` in the tap repository with the new tag's source URL and `sha256`.

By contributing, you agree your contributions are licensed under the MIT License.
