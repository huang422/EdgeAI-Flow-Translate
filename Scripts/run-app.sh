#!/usr/bin/env bash
#
# Build the app (Debug) and launch it. Use this for the local dev loop:
# edit code → run this → the rebuilt app opens. It regenerates the Xcode
# project first, so it also picks up newly added/removed files.
#
# Requires a FULL Xcode install (the Command Line Tools alone cannot build the
# app target). Install Xcode from the App Store, then:
#     sudo xcode-select -s /Applications/Xcode.app
#
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    echo "error: full Xcode is required (found only Command Line Tools)." >&2
    echo "  1) Install Xcode from the App Store" >&2
    echo "  2) sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi
command -v xcodegen >/dev/null || { echo "error: brew install xcodegen"; exit 1; }

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building (Debug)"
xcodebuild \
    -project FlowTranslate.xcodeproj \
    -scheme FlowTranslate \
    -configuration Debug \
    -derivedDataPath build/dev \
    CODE_SIGNING_ALLOWED=NO \
    build

APP="build/dev/Build/Products/Debug/FlowTranslate.app"
[ -d "$APP" ] || { echo "error: build product not found at $APP"; exit 1; }

echo "==> Launching $APP"
open "$APP"
