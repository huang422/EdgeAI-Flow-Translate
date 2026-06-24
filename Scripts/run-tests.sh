#!/usr/bin/env bash
#
# Run the FlowTranslateCore unit tests.
#
# swift-testing ("import Testing") works out of the box under a full Xcode
# toolchain. Under the bare Command Line Tools the test bundle cannot find the
# Testing.framework / lib_TestingInterop.dylib at runtime, so we add the right
# search paths. This script works in both environments.
#
set -euo pipefail
cd "$(dirname "$0")/.."

if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    # Full Xcode toolchain: plain swift test is enough.
    exec swift test
fi

# Command Line Tools fallback: wire up the swift-testing framework rpaths.
FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
INTEROP="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [[ ! -d "$FW/Testing.framework" ]]; then
    echo "error: Testing.framework not found under Command Line Tools." >&2
    echo "Install Xcode, or run the tests from Xcode (Cmd+U)." >&2
    exit 1
fi

DYLD_FRAMEWORK_PATH="$FW" DYLD_LIBRARY_PATH="$INTEROP" \
    swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$INTEROP" \
        "$@"
