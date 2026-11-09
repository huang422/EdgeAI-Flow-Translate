#!/usr/bin/env bash
#
# Build FlowTranslate.app (Release) and package it into a distributable .dmg.
# Requires a full Xcode install (xcodebuild) and XcodeGen.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FlowTranslate"
BUILD_DIR="Packaging/build"
DERIVED="build/release"
EXPORT_DIR="$BUILD_DIR/export.noindex"
DMG_PATH="$BUILD_DIR/${APP_NAME}.dmg"

mkdir -p "$DERIVED"
LOCK="$PWD/$DERIVED/.deployment-lock"
if ! mkdir "$LOCK"; then
    echo 'error: another Release install or package is using build/release.' >&2
    exit 1
fi
STAGED_DMG="$BUILD_DIR/.FlowTranslate-next.dmg"
trap 'rm -f "$STAGED_DMG"; rmdir "$LOCK"' EXIT
bash Scripts/build-release.sh
rm -rf "$EXPORT_DIR"

APP_PATH="$DERIVED/Build/Products/Release/${APP_NAME}.app"
[ -d "$APP_PATH" ] || { echo "error: build product not found at $APP_PATH"; exit 1; }

echo "==> Staging app"
mkdir -p "$EXPORT_DIR"
cp -R "$APP_PATH" "$EXPORT_DIR/"
ln -sf /Applications "$EXPORT_DIR/Applications"

# Sign the STAGED app BEFORE packaging (the DMG snapshots its contents — signing
# afterwards used to ship an ad-hoc app inside a "signed" DMG and notarization
# always failed). Runs only when a Developer ID is configured.
if [ -n "${DEVELOPER_ID_APP:-}" ]; then
    echo "==> Signing staged app with Developer ID"
    bash Packaging/sign_app.sh "$EXPORT_DIR/${APP_NAME}.app"
else
    echo "WARNING: DEVELOPER_ID_APP not set — this DMG contains an ad-hoc local build."
    echo "         External distribution requires Developer ID signing and notarization."
fi

echo "==> Creating DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$EXPORT_DIR" \
    -ov -format UDZO \
    "$STAGED_DMG"
hdiutil verify "$STAGED_DMG"
mv "$STAGED_DMG" "$DMG_PATH"

# Only the installed app should remain discoverable by Spotlight.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$APP_PATH" >/dev/null 2>&1 || true
rm -rf "$APP_PATH"
if [[ -z "${DEVELOPER_ID_APP:-}" ]]; then rm -rf "$EXPORT_DIR"; fi
echo "==> Done: $DMG_PATH"
