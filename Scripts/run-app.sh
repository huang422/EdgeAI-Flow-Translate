#!/usr/bin/env bash
# Compatibility alias: running locally now updates the one installed Release.
set -euo pipefail
exec bash "$(dirname "$0")/install-app.sh" "$@"
