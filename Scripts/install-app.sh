#!/usr/bin/env bash
# The single local deployment entry: validate, stage, replace, and launch Release.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/release
LOCK="$PWD/build/release/.deployment-lock"
if ! mkdir "$LOCK"; then
    echo 'error: another Release install or package is using build/release.' >&2
    exit 1
fi
trap 'rmdir "$LOCK"' EXIT
bash Scripts/build-release.sh
APP="$PWD/build/release/Build/Products/Release/FlowTranslate.app"
DEST='/Applications/FlowTranslate.app'
if [[ -e "$DEST" || -L "$DEST" ]]; then
    if [[ ! -d "$DEST" || -L "$DEST" ]] || \
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)" != 'dev.flowtranslate.app' ]]; then
        echo 'error: destination is not a regular FlowTranslate app bundle; it was left untouched.' >&2
        exit 1
    fi
fi
STAGING="$(mktemp -d /Applications/.FlowTranslate-install.XXXXXX)"
REPLACED=false
cleanup() {
    local result=$?
    if [[ $result -ne 0 && "$REPLACED" == true ]]; then
        rm -rf "$DEST"
        if [[ -d "$STAGING/previous.app" ]]; then mv "$STAGING/previous.app" "$DEST"; fi
    fi
    rm -rf "$STAGING"
    rmdir "$LOCK"
    exit "$result"
}
trap cleanup EXIT
# Finish the copy and signature checks before touching any working installation.
ditto "$APP" "$STAGING/FlowTranslate.app"
codesign --verify --strict "$STAGING/FlowTranslate.app"
if pgrep -x FlowTranslate >/dev/null; then
    # A sheet or permission dialog can reject Quit. Some async quit handlers
    # also return an Apple-event cancellation while finishing normally, so the
    # process exit below is the authority, not osascript's immediate exit code.
    if ! osascript -e 'tell application id "dev.flowtranslate.app" to quit'; then
        echo 'FlowTranslate deferred or declined Quit; waiting for normal shutdown.' >&2
    fi
    for ((attempt=0; attempt<150; attempt++)); do
        pgrep -x FlowTranslate >/dev/null || break
        sleep 0.2
    done
    if pgrep -x FlowTranslate >/dev/null; then
        echo 'error: FlowTranslate is still open. Close Settings/permission dialogs and quit normally, then retry make install. The existing installation was preserved.' >&2
        exit 1
    fi
fi
if [[ -d "$DEST" ]]; then mv "$DEST" "$STAGING/previous.app"; fi
REPLACED=true
mv "$STAGING/FlowTranslate.app" "$DEST"
codesign --verify --strict "$DEST"
# Explicit paths avoid Launch Services choosing an old build with the same ID.
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
open "$DEST"
sleep 2
if ! ps -axo comm= | grep -Fx "$DEST/Contents/MacOS/FlowTranslate" >/dev/null; then
    echo 'error: installed app did not stay running; restoring the previous installation.' >&2
    exit 1
fi
# Keep object/dependency caches, but remove the generated app that Spotlight
# would otherwise show as another installed version. The next build recreates it.
if cmp -s "$APP/Contents/MacOS/FlowTranslate" "$DEST/Contents/MacOS/FlowTranslate"; then
    rm -rf "$APP"
fi
echo 'Installed Release at /Applications/FlowTranslate.app. Models, transcripts and preferences were preserved.'
