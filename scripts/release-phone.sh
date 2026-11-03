#!/bin/bash
# Packages terminal-phone for distribution.
#   bash scripts/release-phone.sh            local package, ad-hoc signed (runs on this Mac)
#   bash scripts/release-phone.sh --signed   Developer ID signed and notarized (for public download)
# --signed needs SIGN_IDENTITY ("Developer ID Application: …") and NOTARY_PROFILE (a notarytool
# Keychain profile: xcrun notarytool store-credentials NAME). scripts/release-config.sh sets defaults.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=local
case "${1:-}" in
  "") ;;
  --signed) mode=signed ;;
  --help|-h) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 1 ;;
esac
if [[ $mode = signed ]]; then
  [[ -f scripts/release-config.sh ]] && source scripts/release-config.sh
  [[ "${SIGN_IDENTITY:-}" = "Developer ID Application:"* ]] || { echo 'Set SIGN_IDENTITY to a "Developer ID Application: …" identity.' >&2; exit 1; }
  [[ -n "${NOTARY_PROFILE:-}" ]] || { echo 'Set NOTARY_PROFILE to a notarytool Keychain profile.' >&2; exit 1; }
fi
bash scripts/build-phone.sh
phone_release_version="$(./dist/terminal-phone version | awk '{print $2}')"
[[ "$phone_release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
phone_staging="$(mktemp -d "$PWD/.build/phone-release-XXXXXX")"
trap 'rm -rf "$phone_staging"' EXIT
mkdir -p "$phone_staging/terminal-phone" dist/releases
# This whitelist excludes every personal WDA build, provisioning profile and private dependency cache.
cp dist/terminal-phone "$phone_staging/terminal-phone/"
cp -R dist/resources dist/agent "$phone_staging/terminal-phone/"
cp LICENSE "$phone_staging/terminal-phone/LICENSE"
if [[ $mode = signed ]]; then
  binary="$phone_staging/terminal-phone/terminal-phone"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$binary"
  codesign --verify --strict --verbose=2 "$binary"
  # A bare executable can't be stapled; Gatekeeper fetches its ticket online on first run.
  ditto -c -k --keepParent "$binary" "$phone_staging/notarize.zip"
  xcrun notarytool submit "$phone_staging/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$phone_staging/notary.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$phone_staging/notary.plist")" = Accepted ]] || { cat "$phone_staging/notary.plist"; echo 'Notarization was not accepted.' >&2; exit 1; }
  rm "$phone_staging/notarize.zip" "$phone_staging/notary.plist"
  distribution="Developer ID signed and notarized by Apple."
else
  distribution="Local build, ad-hoc signed: it runs on the Mac that built it. Public downloads use release-phone.sh --signed."
fi
cat > "$phone_staging/terminal-phone/README.txt" <<README
terminal-phone $phone_release_version

Install once:
  ./terminal-phone self install

Then open a new terminal and run:
  terminal-phone

The CLI finds Xcode, downloads a missing iOS simulator and sets up its own
verified phone-control/Python runtime. Homebrew and system Python are not required.
Xcode must be installed from Apple and its first-launch/license steps completed.

Real iPhone:
  terminal-phone connect

The owner must trust the Mac, enable Developer Mode and approve input.
The connection wizard handles device selection and remembers signing configuration.

Home remains visible. Click Enable control if you deliberately opened View only.
Click and type, drag to swipe, wheel to scroll. Ctrl+] exits the viewer.

$distribution
License: MIT (see LICENSE).
README
phone_archive="$PWD/dist/releases/terminal-phone-$phone_release_version-macos-arm64.tar.gz"
tar -czf "$phone_archive" -C "$phone_staging" terminal-phone
# Name only, no local path, so downloaders can run: shasum -a 256 -c FILE.sha256
(cd "$(dirname "$phone_archive")" && shasum -a 256 "$(basename "$phone_archive")" > "$(basename "$phone_archive").sha256")
echo "Packaged ($mode): $phone_archive"
