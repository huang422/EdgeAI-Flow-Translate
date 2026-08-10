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

# Quit any running copy first. `open` on an app bundle activates an instance
# that is already running instead of launching the one just built — so every
# edit appeared to have no effect, because the window brought to the front was
# the old binary. Quitting is the right move rather than `open -n`: two
# instances would contend for the microphone, the global hotkey and the model.
if pgrep -x FlowTranslate >/dev/null 2>&1; then
    echo "==> Quitting the running copy"
    osascript -e 'quit app "FlowTranslate"' >/dev/null 2>&1 || true
    for _ in $(seq 1 25); do
        pgrep -x FlowTranslate >/dev/null 2>&1 || break
        sleep 0.2
    done
    # A hung instance must not silently leave the old build in front.
    pgrep -x FlowTranslate >/dev/null 2>&1 && killall -9 FlowTranslate 2>/dev/null || true
fi

echo "==> Launching $APP"
open "$APP"
