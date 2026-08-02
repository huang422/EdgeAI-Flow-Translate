#!/usr/bin/env bash
#
# Notarize and staple FlowTranslate.dmg for distribution outside the App Store.
#
# PREREQUISITE: the app inside the DMG must already carry a Developer ID
# signature — `build_dmg.sh` signs the staged app (via sign_app.sh) BEFORE
# packaging when DEVELOPER_ID_APP is set. This script only signs the DMG
# container itself, submits it, and staples the ticket.
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

: "${DEVELOPER_ID_APP:?set DEVELOPER_ID_APP}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"
[ -f "$DMG_PATH" ] || { echo "error: DMG not found at $DMG_PATH (run build_dmg.sh first)"; exit 1; }

echo "==> Sanity check: app inside the staged export is Developer ID signed"
codesign --verify --strict --verbose=1 "Packaging/build/export/FlowTranslate.app"
if codesign -dv "Packaging/build/export/FlowTranslate.app" 2>&1 | grep -q "Signature=adhoc"; then
    echo "error: the staged app is ad-hoc signed — DEVELOPER_ID_APP was not set"
    echo "       when build_dmg.sh ran. Re-run build_dmg.sh with signing env."
    exit 1
fi

echo "==> Signing DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG_PATH"

echo "==> Submitting to notary service"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Notarization complete: $DMG_PATH"
