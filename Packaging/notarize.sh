#!/usr/bin/env bash
#
# Code-sign, notarize and staple FlowTranslate.dmg for distribution outside the
# App Store. Requires a Developer ID certificate and a notarytool keychain
# profile.
#
# Required environment variables:
#   DEVELOPER_ID_APP   e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE     name of a stored notarytool keychain profile
#                      (create once with:
#                       xcrun notarytool store-credentials NOTARY_PROFILE \
#                         --apple-id you@example.com --team-id TEAMID --password app-specific-pw)
#
set -euo pipefail
cd "$(dirname "$0")/.."

DMG_PATH="Packaging/build/FlowTranslate.dmg"
APP_PATH="Packaging/build/export/FlowTranslate.app"

: "${DEVELOPER_ID_APP:?set DEVELOPER_ID_APP}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"

echo "==> Signing app (hardened runtime)"
codesign --force --deep --options runtime --timestamp \
    --entitlements FlowTranslate/FlowTranslate.entitlements \
    --sign "$DEVELOPER_ID_APP" \
    "$APP_PATH"

echo "==> Signing DMG"
codesign --force --sign "$DEVELOPER_ID_APP" "$DMG_PATH"

echo "==> Submitting to notary service"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Notarization complete: $DMG_PATH"
