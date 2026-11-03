#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="$PWD/dist/PhoneDemo.app"
mkdir -p "$app" "$PWD/.build/PhoneDemoModules"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -parse-as-library -sdk "$sdk" -target "$(uname -m)-apple-ios18.0-simulator" \
  -module-cache-path "$PWD/.build/PhoneDemoModules" examples/PhoneDemo/App.swift -o "$app/PhoneDemo"
cp examples/PhoneDemo/Info.plist "$app/Info.plist"
codesign --force --sign - "$app"
echo "Built: $app"
