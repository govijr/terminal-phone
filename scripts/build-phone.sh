#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
build_options=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/configuration" --security-path "$PWD/.build/security")
swift build "${build_options[@]}" -c release --product terminal-phone
binary_dir="$(swift build "${build_options[@]}" -c release --show-bin-path)"
mkdir -p dist
mkdir -p dist/resources
cp resources/phone-viewer-worker.py dist/resources/phone-viewer-worker.py
cp resources/phone-agent-worker.py dist/resources/phone-agent-worker.py
cp resources/phone-idb-requirements.txt dist/resources/phone-idb-requirements.txt
mkdir -p dist/agent
cp docs/TERMINAL-PHONE-AGENT.md dist/agent/AGENT.md
mkdir -p dist/agent/skills/terminal-phone
cp plugins/terminal-phone/skills/terminal-phone/SKILL.md dist/agent/skills/terminal-phone/SKILL.md
cp "$binary_dir/terminal-phone" dist/terminal-phone
codesign --force --sign - dist/terminal-phone
codesign --verify --strict dist/terminal-phone
echo "Built: $PWD/dist/terminal-phone"
