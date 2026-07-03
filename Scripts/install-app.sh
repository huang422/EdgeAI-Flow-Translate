#!/usr/bin/env bash
#
# Build a Release app and INSTALL it into /Applications, replacing any older
# copy, then launch it. Use this to "update the app on your Mac" after code
# changes (as opposed to `make run`, which only runs a throwaway dev build).
#
# Requires a full Xcode install.
#
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    echo "error: full Xcode required. Run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi
command -v xcodegen >/dev/null || { echo "error: brew install xcodegen"; exit 1; }

DEST="/Applications/FlowTranslate.app"

echo "==> Generating project"
xcodegen generate

echo "==> Building (Release)"
xcodebuild \
    -project FlowTranslate.xcodeproj \
    -scheme FlowTranslate \
    -configuration Release \
    -derivedDataPath build/release \
    CODE_SIGNING_ALLOWED=NO \
    build

APP="build/release/Build/Products/Release/FlowTranslate.app"
[ -d "$APP" ] || { echo "error: build product not found at $APP"; exit 1; }

echo "==> Quitting any running instance"
osascript -e 'quit app "FlowTranslate"' 2>/dev/null || true
pkill -x FlowTranslate 2>/dev/null || true
sleep 1

echo "==> Removing old version at $DEST (if any)"
rm -rf "$DEST"

# TCC keys privacy grants to the app's code signature. Each unsigned rebuild has
# a new signature, so the old Microphone / Screen Recording entries go stale
# (toggle looks ON but capture fails). Reset them so the new build prompts fresh.
echo "==> Resetting stale privacy (TCC) entries"
tccutil reset Microphone dev.flowtranslate.app 2>/dev/null || true
tccutil reset ScreenCapture dev.flowtranslate.app 2>/dev/null || true

echo "==> Installing new version"
cp -R "$APP" "$DEST"

echo "==> Launching $DEST"
open "$DEST"

echo "==> Installed FlowTranslate to /Applications."
