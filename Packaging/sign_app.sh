#!/usr/bin/env bash
#
# Sign the STAGED FlowTranslate.app with a Developer ID certificate + hardened
# runtime, inside-out (nested code first, main bundle last). Must run BEFORE the
# DMG is created — signing after packaging leaves the DMG carrying the unsigned
# app and notarization rejects it.
#
# `codesign --deep` is deliberately NOT used: it is deprecated for distribution
# signing and mis-signs nested bundles with their own entitlements/identifiers.
#
# Required environment variables:
#   DEVELOPER_ID_APP   e.g. "Developer ID Application: Your Name (TEAMID)"
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${1:-Packaging/build/export/FlowTranslate.app}"
ENTITLEMENTS="FlowTranslate/FlowTranslate.entitlements"

: "${DEVELOPER_ID_APP:?set DEVELOPER_ID_APP}"
[ -d "$APP_PATH" ] || { echo "error: app not found at $APP_PATH"; exit 1; }

echo "==> Signing nested code (deepest first)"
# Frameworks / dylibs / plug-ins / nested bundles must be signed before the
# enclosing app. `-depth` yields deepest paths first.
while IFS= read -r -d '' item; do
    echo "    signing: ${item#"$APP_PATH"/}"
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APP" "$item"
done < <(find "$APP_PATH/Contents" -depth \
        \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" \
           -o -name "*.bundle" -o -name "*.appex" \) -print0 2>/dev/null)

echo "==> Signing main app (hardened runtime + entitlements)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APP" \
    "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_PATH"

echo "==> App signed: $APP_PATH"
