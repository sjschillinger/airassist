#!/usr/bin/env bash
# Build AirAssist.app + the integration runner, then run the runner.
#
# Why this script exists: `xcodebuild test` doesn't work for this suite.
# The tests SIGKILL and SIGTERM AirAssist to verify crash-recovery /
# signal-handler paths, but every xctest packaging hosts the test code
# inside an app bundle — so signals land on the harness too. See the
# AirAssistIntegrationRunner target comment in project.yml for the long
# version.
#
# Usage:
#   scripts/run-integration.sh                                 # run all
#   scripts/run-integration.sh test_16_SIGSTOPLands            # run one
#   scripts/run-integration.sh --list                          # list tests
#   scripts/run-integration.sh --no-build test_35_*            # skip xcodebuild
#
# Exit code mirrors the runner's: 0 on full pass, 1 on any fail.

set -euo pipefail

cd "$(dirname "$0")/.."

NO_BUILD=0
if [[ "${1:-}" == "--no-build" ]]; then
    NO_BUILD=1
    shift
fi

if [[ "$NO_BUILD" -eq 0 ]]; then
    echo "→ Building AirAssist.app + AirAssistIntegrationRunner (Debug)..."
    # xcpretty would be nicer but keep zero-dep for clone-and-go.
    xcodebuild \
        -project AirAssist.xcodeproj \
        -scheme AirAssist \
        -configuration Debug \
        build \
        -quiet
fi

# Locate BUILT_PRODUCTS_DIR. -showBuildSettings is the canonical way;
# grep it out rather than parsing the whole dump.
BUILT_PRODUCTS_DIR=$(xcodebuild \
    -project AirAssist.xcodeproj \
    -scheme AirAssist \
    -configuration Debug \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')

RUNNER="$BUILT_PRODUCTS_DIR/AirAssistIntegrationRunner"

if [[ ! -x "$RUNNER" ]]; then
    echo "error: runner binary not found at $RUNNER" >&2
    echo "       Did the build fail silently? Try without -quiet." >&2
    exit 2
fi

echo "→ Running: $RUNNER $*"
exec "$RUNNER" "$@"
