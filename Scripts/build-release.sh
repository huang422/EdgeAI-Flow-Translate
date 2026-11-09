#!/usr/bin/env bash
# Shared, incremental Release build for local installation and DMG packaging.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'error: install XcodeGen: brew install xcodegen' >&2; exit 1; }
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if (( ${SDK_VERSION%%.*} < 26 )); then
    echo 'error: Xcode 26+ with the macOS 26+ SDK is required (the app still runs on macOS 15+).' >&2
    exit 1
fi
if ! xcrun metal --version >/dev/null 2>&1; then
    echo 'error: Apple Metal Toolchain is missing. Install once: xcodebuild -downloadComponent MetalToolchain' >&2
    exit 1
fi
bash Scripts/run-tests.sh
bash Scripts/generate-project.sh
xcodebuild -project FlowTranslate.xcodeproj -scheme FlowTranslate \
    -configuration Release -derivedDataPath build/release -jobs 4 \
    -destination 'generic/platform=macOS' \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES build
APP='build/release/Build/Products/Release/FlowTranslate.app'
codesign --verify --strict --verbose=1 "$APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/FlowTranslate")" == arm64 ]] || { echo 'error: expected an Apple Silicon-only Release' >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" | grep -qx 'dev.flowtranslate.app'
EXPECTED_VERSION="$(tr -d '[:space:]' < version.txt)"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || { echo 'error: App version differs from version.txt' >&2; exit 1; }
