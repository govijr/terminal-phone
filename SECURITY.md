# Security policy

terminal-phone can control simulators and, with the owner's approval, real iPhones. Please take security reports seriously, and report them privately.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** on this repository (Security → Report a vulnerability). Please don't open a public issue for security problems. Include the version (`terminal-phone version`), your macOS and Xcode versions, and steps to reproduce.

You should get an acknowledgement within a few days. Fixes are released as a new version and noted in the release notes.

## What is in scope

Especially:

- Any way for an agent, MCP client, app content or another local user to send input to a real iPhone without the owner's grant, or to change that grant.
- Escaping the per-user socket directory, controlling another user's phone, or replaying input after an uncertain outcome.
- Setup downloading or executing anything that isn't checksum-verified.
- The installer modifying files other than its own launcher, runtime and the one PATH line it documents.

## Design notes

- Real iPhones are view-only until the owner approves input with `terminal-phone connect` or `--allow-input`. The grant is re-read on every request.
- Local control sockets live in a user-owned `0700` directory with `0600` sockets and peer-ownership checks.
- Runtime downloads (idb_companion, Python, WebDriverAgent source, Python wheels) are pinned by SHA-256.
- Screen text and screenshots are treated as untrusted data in the agent guide. Screenshots aren't pixel-redacted, so treat them as sensitive.
