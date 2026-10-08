#!/bin/bash
# Runs the Swift Testing suites. Extra arguments are passed to `swift test`
# (e.g. `--filter PARSER_001`).
#
# Works around a swift-build bug with Command Line Tools where the
# TestingMacros plugin is sometimes not passed to the compiler.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGIN_DIR="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/host/plugins/testing"
EXTRA=()
if [ -d "$PLUGIN_DIR" ]; then
    EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi
exec swift test "${EXTRA[@]}" "$@"
