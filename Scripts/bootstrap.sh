#!/usr/bin/env bash
#
# Developer bootstrap: generate the Xcode project and open it.
# Installs XcodeGen via Homebrew if missing.
#
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
    echo "==> Installing XcodeGen"
    command -v brew >/dev/null || { echo "error: Homebrew required (https://brew.sh)"; exit 1; }
    brew install xcodegen
fi

echo "==> Generating FlowTranslate.xcodeproj from project.yml"
xcodegen generate

echo "==> Opening project"
open FlowTranslate.xcodeproj
