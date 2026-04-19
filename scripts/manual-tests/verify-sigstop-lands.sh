#!/usr/bin/env bash
#
# verify-sigstop-lands.sh — checklist item #16
#
# Asserts that AirAssist's throttler actually SIGSTOPs the target PID
# during a throttle cycle. Without this, the rest of the throttling
# story is theater.
#
# Expected state under throttling: `ps -o stat` for the target PID
# oscillates between `R`/`S` (running or sleeping) and `T` (stopped)
# as the duty cycler toggles it. A low-duty throttle (e.g., 0.1) will
# spend most of each 100ms cycle in `T`, so a sample every 20ms for a
# second should include at least one `T` sighting.
#
# Prerequisites (the script will refuse to run without them):
#   1. AirAssist.app is running
#   2. The rule engine is enabled in Preferences → Rules
#   3. A rule targeting the name "yes" with duty 0.1 exists
#      (the script will nudge you to add it and wait)
#
# See docs/engineering-references.md §1 for SIGSTOP semantics and
# §4 for how process state maps to `ps` STAT codes.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RESET='\033[0m'

banner() { printf "\n${YELLOW}%s${RESET}\n" "$1"; }
pass()   { printf "${GREEN}PASS:${RESET} %s\n" "$1"; }
fail()   { printf "${RED}FAIL:${RESET} %s\n" "$1"; exit 1; }

TARGET_PID=""
cleanup() {
    if [[ -n "$TARGET_PID" ]] && kill -0 "$TARGET_PID" 2>/dev/null; then
        kill "$TARGET_PID" 2>/dev/null || true
        # Make sure the cycler isn't holding it SIGSTOPed after kill.
        sleep 0.2
        kill -CONT "$TARGET_PID" 2>/dev/null || true
        wait "$TARGET_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

banner "verify-sigstop-lands.sh — #16"

# --- Prereq: AirAssist running
if ! pgrep -x AirAssist >/dev/null; then
    fail "AirAssist is not running. Launch it first."
fi
pass "AirAssist is running"

# --- Prereq: a rule matching 'yes' with low duty
cat <<EOF

${YELLOW}Manual setup required:${RESET}
  1. Open AirAssist Preferences → Rules
  2. Enable the Rules engine (top toggle)
  3. Add a rule for executable name "yes" at duty 0.10 (10%)
  4. Save and leave Preferences open

Press ENTER when the rule is in place, or Ctrl-C to abort.
EOF
read -r

# --- Spawn the target
TARGET_PID=$( (yes > /dev/null & echo $!) )
sleep 0.5
if ! kill -0 "$TARGET_PID" 2>/dev/null; then
    fail "Could not spawn 'yes' target process"
fi
pass "spawned target 'yes' pid=$TARGET_PID"

# Give AirAssist a tick or two to notice and install the throttle.
sleep 2

# --- Sample ps STAT 50 times over ~1 second
banner "sampling ps STAT for $TARGET_PID (50 samples over ~1s)..."
STOPPED_HITS=0
RUNNING_HITS=0
OTHER_HITS=0
for _ in $(seq 1 50); do
    STAT=$(ps -o stat= -p "$TARGET_PID" 2>/dev/null || echo "X")
    case "$STAT" in
        T*) STOPPED_HITS=$((STOPPED_HITS + 1)) ;;
        R*|S*|U*) RUNNING_HITS=$((RUNNING_HITS + 1)) ;;
        *) OTHER_HITS=$((OTHER_HITS + 1)) ;;
    esac
    sleep 0.02
done

printf "  stopped (T)   hits: %d\n" "$STOPPED_HITS"
printf "  running (R/S) hits: %d\n" "$RUNNING_HITS"
printf "  other/unknown hits: %d\n" "$OTHER_HITS"

# --- Assert
if [[ "$STOPPED_HITS" -eq 0 ]]; then
    fail "never observed SIGSTOP ('T' state) on the target. Rule not firing?"
fi
if [[ "$RUNNING_HITS" -eq 0 ]]; then
    fail "never observed the process running. Either it died or the rule is hard-pausing (duty effectively 0)."
fi

pass "duty cycler is alternating SIGSTOP/SIGCONT as expected"
banner "OK — #16 verified."
