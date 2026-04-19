#!/usr/bin/env bash
#
# verify-sleep-wake.sh — checklist item #18
#
# Asserts that AirAssist releases every throttled PID when the machine
# goes to sleep, so a paused process can't be stranded through a long
# sleep cycle (the user would come back to a frozen Slack, etc.).
#
# Verifies SleepWakeObserver wiring — it listens on
# NSWorkspace.shared.notificationCenter for willSleepNotification and
# calls processThrottler.releaseAll() on the main actor before the
# system actually sleeps.
#
# Procedure (fully automated where possible, interactive for the
# sleep itself since we can't force a real sleep from a shell without
# `pmset sleepnow`):
#   1. Confirm the 'yes' duty-0.10 rule from #16 is active.
#   2. Spawn a target and confirm it's being duty-cycled.
#   3. Run `pmset sleepnow` (or ask the user to close the lid).
#   4. On wake, confirm the target was released (STAT is not 'T')
#      even before AirAssist's next control-loop tick.
#
# Note on pmset: sleep requires the machine to actually be able to
# sleep. External display, active video call, or a power-assertion
# holding it awake can silently no-op. The script checks
# `pmset -g assertions` before sleeping and bails with a hint if
# anything is holding the display or system awake.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RESET='\033[0m'
banner() { printf "\n${YELLOW}%s${RESET}\n" "$1"; }
pass()   { printf "${GREEN}PASS:${RESET} %s\n" "$1"; }
fail()   { printf "${RED}FAIL:${RESET} %s\n" "$1"; exit 1; }

TARGET_PID=""
cleanup() {
    if [[ -n "$TARGET_PID" ]] && kill -0 "$TARGET_PID" 2>/dev/null; then
        kill -CONT "$TARGET_PID" 2>/dev/null || true
        kill        "$TARGET_PID" 2>/dev/null || true
        wait        "$TARGET_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

banner "verify-sleep-wake.sh — #18"

pgrep -x AirAssist >/dev/null || fail "AirAssist is not running."
pass "AirAssist is running"

cat <<EOF
${YELLOW}Manual setup required:${RESET}
  Same setup as #16: rule matching 'yes' at duty 0.10, rule engine on.
  Also make sure AirAssist's own Stay-Awake is OFF — otherwise it'll
  hold the machine awake and pmset sleepnow won't actually sleep.
  Press ENTER when ready.
EOF
read -r

# --- Spawn target
TARGET_PID=$( (yes > /dev/null & echo $!) )
sleep 2
pass "spawned target 'yes' pid=$TARGET_PID"

# --- Confirm throttling
HITS=0
for _ in $(seq 1 30); do
    S=$(ps -o stat= -p "$TARGET_PID" 2>/dev/null | tr -d ' ')
    [[ "$S" == T* ]] && HITS=$((HITS+1))
    sleep 0.05
done
[[ "$HITS" -gt 0 ]] || fail "target never SIGSTOPed — rule not firing?"
pass "target is being duty-cycled"

# --- Check nothing is holding sleep off
ASSERTIONS=$(pmset -g assertions 2>/dev/null || echo "")
if echo "$ASSERTIONS" | grep -qE 'PreventUserIdleSystemSleep.*1|NoIdleSleepAssertion.*1'; then
    banner "power assertions currently blocking sleep:"
    echo "$ASSERTIONS" | grep -E '1\s*$' || true
    fail "something is holding the system awake. Close video calls / Stay Awake / caffeinate and rerun."
fi
pass "no blocking power assertions"

# --- Ask for sleep
cat <<EOF

${YELLOW}Manual action required:${RESET}
  About to trigger system sleep. The script will pause here.
  When the Mac wakes up, unlock and return to this terminal.

  You can close the lid OR press ENTER to run 'pmset sleepnow'.
EOF
read -r
banner "running pmset sleepnow..."
pmset sleepnow || fail "pmset sleepnow failed — may need sudo, or system cannot sleep"

# When we get here, the machine woke up.
banner "welcome back — checking target state within 500ms of wake..."
sleep 0.5
STAT=$(ps -o stat= -p "$TARGET_PID" 2>/dev/null | tr -d ' ' || echo "X")
[[ "$STAT" != T* ]] || fail "target is still SIGSTOPed after wake (STAT=$STAT) — sleep-release path broken"
pass "target is not SIGSTOPed after wake (STAT=$STAT)"

banner "OK — #18 verified."
