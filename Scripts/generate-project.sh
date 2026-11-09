#!/usr/bin/env bash
# Restore the reviewed dependency graph after generating the ignored project.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
mkdir -p FlowTranslate.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Dependencies/Package.resolved FlowTranslate.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
