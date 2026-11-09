#!/usr/bin/env bash
# Make an isolated UI-only fixture from an already built Release; no models/TCC.
# Usage: bash Scripts/prepare-ui-fixture.sh [scenario] [width] [height]
set -euo pipefail
cd "$(dirname "$0")/.."
SCENARIO="${1:-first-launch}"
FIXTURE_DIR="$(mktemp -d /private/tmp/flowtranslate-ui.XXXXXX)"
FIXTURE_APP="$FIXTURE_DIR/FlowTranslate QA.app"
SOURCE_APP="build/release/Build/Products/Release/FlowTranslate.app"
[[ -d "$SOURCE_APP" ]] || SOURCE_APP="/Applications/FlowTranslate.app"
[[ -d "$SOURCE_APP" ]] || { echo "error: build or install Release before preparing a fixture" >&2; exit 1; }
ditto "$SOURCE_APP" "$FIXTURE_APP"
python3 - "$FIXTURE_APP/Contents/Info.plist" "$SCENARIO" "${2:-940}" "${3:-620}" <<'PY'
import plistlib,sys,uuid
from pathlib import Path
path=Path(sys.argv[1]); data=plistlib.loads(path.read_bytes())
fixture_id=uuid.uuid4().hex
data.update(CFBundleIdentifier='dev.flowtranslate.fixture.'+fixture_id,
            CFBundleName='FlowTranslate QA '+fixture_id[:6], CFBundleDisplayName='FlowTranslate QA '+fixture_id[:6],
            CFBundleExecutable='FlowTranslateQA', FlowTranslateUIFixture=True,
            FlowTranslateFixtureScenario=sys.argv[2],
            FlowTranslateFixtureWidth=float(sys.argv[3]), FlowTranslateFixtureHeight=float(sys.argv[4]))
path.write_bytes(plistlib.dumps(data))
(path.parent/'MacOS/FlowTranslate').rename(path.parent/'MacOS/FlowTranslateQA')
PY
codesign --force --sign - --options runtime --entitlements FlowTranslate/FlowTranslate.entitlements "$FIXTURE_APP" >&2
codesign --verify --strict "$FIXTURE_APP"
printf '%s\n' "$FIXTURE_APP"
