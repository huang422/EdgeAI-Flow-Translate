#!/usr/bin/env bash
#
# Build FlowTranslate.app (Release) and package it into a distributable .dmg.
# Requires a full Xcode install (xcodebuild) and XcodeGen.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FlowTranslate"
SCHEME="FlowTranslate"
BUILD_DIR="Packaging/build"
DERIVED="$BUILD_DIR/DerivedData"
EXPORT_DIR="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/${APP_NAME}.dmg"

echo "==> Generating Xcode project from project.yml"
command -v xcodegen >/dev/null || { echo "error: install xcodegen (brew install xcodegen)"; exit 1; }
xcodegen generate

echo "==> Building ${SCHEME} (Release)"
rm -rf "$DERIVED" "$EXPORT_DIR"
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" \
    build

APP_PATH="$DERIVED/Build/Products/Release/${APP_NAME}.app"
[ -d "$APP_PATH" ] || { echo "error: build product not found at $APP_PATH"; exit 1; }

echo "==> Staging app"
mkdir -p "$EXPORT_DIR"
cp -R "$APP_PATH" "$EXPORT_DIR/"
ln -sf /Applications "$EXPORT_DIR/Applications"

echo "==> Creating DMG"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$EXPORT_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "==> Done: $DMG_PATH"
