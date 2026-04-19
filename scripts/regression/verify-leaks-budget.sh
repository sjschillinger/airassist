#!/usr/bin/env bash
# verify-leaks-budget.sh — pre-tag regression gate for #49.
#
# Replays a compressed version of the 1-hour leaks run (10 minutes instead
# of 60) against a freshly-built AirAssist and asserts:
#
#   1. ABSOLUTE:  no leak stack may contain an AirAssist frame.
#                 (Today: all 296 leaks trace to Apple's NSHostingView
#                 _resetDragMarginsIfNeeded — zero AirAssist frames. If
#                 that ever changes, we need to know before we tag.)
#
#   2. BUDGET:    total leaked bytes <= 15_000 over a 10-min run.
#                 (Baseline was ~0.5 KB/min under pathological churn →
#                 ~5 KB expected. 3× that catches amplified regressions.)
#
#   3. COUNT:     leak count <= 150.
#                 (Baseline ~50 leaks at 10 min. 3× headroom.)
#
# Run this before `git tag vX.Y.Z`. If any check fails, read the dump at
# /tmp/airassist-regression/leaks.txt and decide before cutting.
#
# Usage:
#   scripts/regression/verify-leaks-budget.sh                # default 10-min run
#   LEAKS_DURATION_SEC=300 scripts/regression/verify-leaks-budget.sh   # shorter
#
# Requires: xcodebuild, leaks (Apple CLT), AirAssist running sandbox off
# for MallocStackLogging. Run from the repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

DURATION_SEC="${LEAKS_DURATION_SEC:-600}"   # 10 minutes
CHURN_INTERVAL=30
LOG_DIR="/tmp/airassist-regression"
LEAKS_DUMP="$LOG_DIR/leaks.txt"
SUMMARY="$LOG_DIR/summary.txt"

# Budgets — keep in sync with _inbox/leaks-1hr-findings.md baseline.
MAX_LEAKED_BYTES=15000
MAX_LEAK_COUNT=150

mkdir -p "$LOG_DIR"
: > "$SUMMARY"

say() { printf '[regression-gate] %s\n' "$*" | tee -a "$SUMMARY"; }
fail() { printf '[regression-gate] FAIL: %s\n' "$*" | tee -a "$SUMMARY" >&2; exit 1; }

say "started at $(date '+%F %T'), duration=${DURATION_SEC}s"

# --- Step 1: clean build -------------------------------------------------
say "building AirAssist (Debug, no TSan)…"
xcodebuild -project AirAssist.xcodeproj -scheme AirAssist \
    -configuration Debug build >"$LOG_DIR/build.log" 2>&1 \
    || fail "build failed — see $LOG_DIR/build.log"

APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/AirAssist-*/Build/Products/Debug/AirAssist.app 2>/dev/null | head -1)
[ -n "$APP_PATH" ] || fail "could not locate built AirAssist.app"
say "built: $APP_PATH"

# --- Step 2: launch w/ MallocStackLogging so leaks gets stack traces ------
pkill -f AirAssist 2>/dev/null || true
sleep 1
say "launching with MallocStackLogging=1…"
MallocStackLogging=1 open -a "$APP_PATH"
sleep 3

AA_PID=$(pgrep -x AirAssist | head -1)
[ -n "$AA_PID" ] || fail "AirAssist did not start"
say "pid=$AA_PID"

# --- Step 3: drive churn for DURATION_SEC seconds ------------------------
START=$(date +%s)
DEADLINE=$((START + DURATION_SEC))
I=0
say "driving churn for ${DURATION_SEC}s…"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    case $((I % 8)) in
        0) open "airassist://debug/open-dashboard" ;;
        1) open "airassist://debug/stay-awake?mode=system" ;;
        2) open "airassist://debug/open-preferences" ;;
        3) open "airassist://debug/stay-awake?mode=display" ;;
        4) open "airassist://debug/seed-rule?bundle=com.apple.Safari&duty=0.5&enabled=true" ;;
        5) open "airassist://debug/stay-awake?mode=off" ;;
        6) open "airassist://debug/clear-rules" ;;
        7) open "airassist://pause?duration=30s" ;;
    esac >/dev/null 2>&1
    I=$((I + 1))
    sleep "$CHURN_INTERVAL"
    kill -0 "$AA_PID" 2>/dev/null || fail "AirAssist died during churn"
done

# --- Step 4: sample leaks ------------------------------------------------
say "sampling leaks…"
leaks "$AA_PID" > "$LEAKS_DUMP" 2>/dev/null || true

LEAK_COUNT=$(awk '/leaks for/{print $3; exit}' "$LEAKS_DUMP")
LEAK_BYTES=$(awk '/leaks for/{print $5; exit}' "$LEAKS_DUMP")
LEAK_COUNT=${LEAK_COUNT:-0}
LEAK_BYTES=${LEAK_BYTES:-0}
say "leaks observed: count=$LEAK_COUNT  bytes=$LEAK_BYTES"

# --- Step 5: ABSOLUTE — no AirAssist frames in any leak stack ------------
# Apple framework leaks reference CoreGraphics / AppKit / SwiftUI / Hosting
# symbols. An AirAssist-introduced leak would reference "AirAssist" in the
# module or symbol name (e.g. `AirAssist.ThermalStore.start()`).
if grep -qE '\bAirAssist\b' "$LEAKS_DUMP"; then
    grep -nE '\bAirAssist\b' "$LEAKS_DUMP" | head -20 | tee -a "$SUMMARY"
    fail "AirAssist frame(s) detected in leak stacks — not an Apple framework leak. Investigate."
fi
say "absolute check: no AirAssist frames in any leak stack ✓"

# --- Step 6: BUDGET + COUNT ---------------------------------------------
if [ "$LEAK_BYTES" -gt "$MAX_LEAKED_BYTES" ]; then
    fail "leaked bytes $LEAK_BYTES > budget $MAX_LEAKED_BYTES (3× baseline). Apple regression or new source?"
fi
say "byte budget: $LEAK_BYTES <= $MAX_LEAKED_BYTES ✓"

if [ "$LEAK_COUNT" -gt "$MAX_LEAK_COUNT" ]; then
    fail "leak count $LEAK_COUNT > budget $MAX_LEAK_COUNT (3× baseline)."
fi
say "count budget: $LEAK_COUNT <= $MAX_LEAK_COUNT ✓"

# --- Step 7: tidy up -----------------------------------------------------
pkill -f AirAssist 2>/dev/null || true

say "PASS — leaks regression gate clear. Dump: $LEAKS_DUMP"
exit 0
