#!/bin/bash
# Builds Misento.app (app + Live Activity widget extension) for the iOS simulator, no Xcode project needed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
out="$root/dist/Misento.app"
work="$root/.build/ImportDemo"
appex="$out/PlugIns/MisentoWidgets.appex"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
target="$(uname -m)-apple-ios18.0-simulator"
rm -rf "$out"; mkdir -p "$appex" "$work/modules"

swiftc() { xcrun --sdk iphonesimulator swiftc -parse-as-library -sdk "$sdk" -target "$target" \
  -module-cache-path "$work/modules" -swift-version 5 "$@"; }

# App icon through actool, so the home screen shows it.
icons="$work/Assets.xcassets/AppIcon.appiconset"; mkdir -p "$icons"
if [ ! -f "$work/icon.png" ]; then
  xcrun swift "$here/make-icon.swift" "$work/icon.png"
  sips -z 1024 1024 "$work/icon.png" >/dev/null   # NSImage renders at 2x on Retina Macs
fi
cp "$work/icon.png" "$icons/icon.png"
cat > "$icons/Contents.json" <<JSON
{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
JSON
echo '{"info":{"author":"xcode","version":1}}' > "$work/Assets.xcassets/Contents.json"
xcrun actool "$work/Assets.xcassets" --compile "$out" --platform iphonesimulator \
  --minimum-deployment-target 18.0 --app-icon AppIcon --target-device iphone \
  --output-partial-info-plist "$work/icon-info.plist" --output-format human-readable-text >/dev/null

swiftc "$here/App/App.swift" "$here/Shared/ImportAttributes.swift" -o "$out/Misento"
cp "$here/App/Info.plist" "$out/Info.plist"
/usr/libexec/PlistBuddy -c "Merge $work/icon-info.plist" "$out/Info.plist" >/dev/null

swiftc -application-extension -Xlinker -e -Xlinker _NSExtensionMain "$here/Widget/Widget.swift" "$here/Shared/ImportAttributes.swift" -o "$appex/MisentoWidgets"
cp "$here/Widget/Info.plist" "$appex/Info.plist"

codesign --force --sign - "$appex"
codesign --force --sign - "$out"
echo "Built: $out"
