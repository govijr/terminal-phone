#!/bin/bash
# Installs the latest terminal-phone release:
#   curl -fsSL https://raw.githubusercontent.com/govijr/terminal-phone/main/install.sh | bash
# Pin a version with TERMINAL_PHONE_VERSION=0.3.2. Options after `bash -s --` go to `terminal-phone self install`
# (for example --prefix PATH or --no-path).
set -euo pipefail

# Everything runs inside main so a partial download can't execute half a script.
main() {
  local repo=govijr/terminal-phone
  if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "terminal-phone needs an Apple silicon Mac." >&2; exit 1
  fi
  local version="${TERMINAL_PHONE_VERSION:-}"
  if [[ -z "$version" ]]; then
    # The releases/latest page redirects to the newest tag; this avoids the rate-limited GitHub API.
    local latest
    latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")"
    version="${latest##*/v}"
  fi
  version="${version#v}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Couldn't find the latest terminal-phone release. Set TERMINAL_PHONE_VERSION and try again." >&2; exit 1
  fi
  local package="terminal-phone-$version-macos-arm64.tar.gz"
  local base="https://github.com/$repo/releases/download/v$version"
  # Global, not local: the EXIT trap runs after main returns, when a local would be gone.
  work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-phone-install.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  echo "Downloading terminal-phone ${version}..."
  # curl doesn't set the quarantine flag, so macOS runs the ad-hoc signed binary without a warning.
  curl -fsSL -o "$work/$package" "$base/$package"
  curl -fsSL -o "$work/$package.sha256" "$base/$package.sha256"
  (cd "$work" && shasum -a 256 -c "$package.sha256" >/dev/null) || { echo "The download failed its checksum. Try again." >&2; exit 1; }
  tar -xzf "$work/$package" -C "$work"
  "$work/terminal-phone/terminal-phone" self install "$@" </dev/null
}

main "$@"
