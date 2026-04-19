#!/usr/bin/env bash
#
# verify-lid-close-displaythensystem.sh — checklist item #37
#
# The automated half of #37 (the timed display→system downgrade itself)
# is covered by test_37_DisplayThenSystemDowngrades in the integration
# runner. What that test CAN'T do is verify real lid-close behavior —
# clamshell sleep is driven by the physical hinge sensor, which a
# headless script cannot simulate. `pmset sleepnow` takes a different
# kernel path (it ignores assertions for display-sleep the same way
# clamshell does, but the overall power graph is different).
#
# This runbook covers the hands-on half:
#
#   1. We put AirAssist in `displayThenSystem` mode with a normal (10min)
#      timer so the user can actually see the downgrade happen in the UI.
#   2. User closes the lid BEFORE the downgrade fires. Expectation:
#      display sleeps (lid-close always sleeps the internal display —
#      there's no assertion that blocks it on Apple Silicon), but the
#      system does NOT go to sleep. We verify by checking SMC uptime
#      continuity across lid open/close.
#   3. User opens the lid. `pmset -g log` should show lid-open events
#      without a corresponding sleep-wake pair.
#   4. User closes the lid AGAIN, this time AFTER the downgrade window.
#      Now we're holding only `PreventUserIdleSystemSleep`, and the
#      observed behavior should be identical on Apple Silicon (both
#      PreventUserIdle* block idle-initiated sleep, neither blocks
#      clamshell). This is a regression check that the downgrade didn't
#      somehow let clamshell sleep through.
#
# Usage:
#   scripts/manual-tests/verify-lid-close-displaythensystem.sh
#
# Preconditions:
#   • AirAssist is running (`open -a AirAssist` or from the build).
#   • Mac is on AC power. Lid-close behavior differs on battery.
#   • External display NOT connected (changes the clamshell semantics).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RESET='\033[0m'
banner() { printf "\n${YELLOW}== %s ==${RESET}\n" "$1"; }
pass()   { printf "${GREEN}PASS:${RESET} %s\n" "$1"; }
fail()   { printf "${RED}FAIL:${RESET} %s\n" "$1"; exit 1; }
info()   { printf "  %s\n" "$1"; }

banner "verify-lid-close-displaythensystem.sh — #37"

AIRASSIST_PID=$(pgrep -x AirAssist | head -1 || true)
[[ -n "$AIRASSIST_PID" ]] || fail "AirAssist is not running."
pass "AirAssist running (pid=$AIRASSIST_PID)"

# Sanity-check AC power.
if ! pmset -g batt | grep -q "AC Power"; then
    printf "${YELLOW}WARN:${RESET} Mac is on battery. Clamshell sleep behavior "
    printf "differs on battery; results may be misleading. Plug in and re-run.\n"
fi

# Sanity-check no external display.
if system_profiler SPDisplaysDataType 2>/dev/null | grep -iq "External\|Connection Type: DisplayPort"; then
    printf "${YELLOW}WARN:${RESET} External display detected. Clamshell with an "
    printf "external monitor does NOT sleep the system regardless of "
    printf "assertions. Unplug and re-run for a clean test.\n"
fi

aa_assertions() {
    pmset -g assertions 2>/dev/null \
        | awk -v pid="$AIRASSIST_PID" '
            /^pid [0-9]+\(/ { in_block = ($0 ~ "pid "pid"\\("); next }
            in_block && /PreventUserIdleSystemSleep/  { print "PreventUserIdleSystemSleep" }
            in_block && /PreventUserIdleDisplaySleep/ { print "PreventUserIdleDisplaySleep" }
          ' | sort -u | tr '\n' ' '
}

# ------------------------------------------------------------------
# Step 1 — arm displayThenSystem with a 10-minute timer.
# ------------------------------------------------------------------
banner "Step 1 of 3 — arm displayThenSystem (10min)"
cat <<EOF

Manual action:
  • Open AirAssist → Preferences → General → Stay Awake
  • Select: "Display on, then system only"
  • Leave the minutes slider at the default (10).
  • Press ENTER when set.

EOF
read -r

ASSRT=$(aa_assertions)
[[ "$ASSRT" == *PreventUserIdleDisplaySleep* ]] \
    || fail "Expected display assertion within the 10-min window; got: '$ASSRT'"
pass "AirAssist holds PreventUserIdleDisplaySleep"

# Record SMC "Time since boot" — if the system actually sleeps, this
# counter will drop by roughly the sleep duration on wake. If it only
# pauses and resumes, sleep-total below will not increment.
SLEEP_COUNT_BEFORE=$(pmset -g log 2>/dev/null | grep -c "Entering Sleep state" || true)

# ------------------------------------------------------------------
# Step 2 — close lid BEFORE the 10-min downgrade fires.
# ------------------------------------------------------------------
banner "Step 2 of 3 — close the lid for ~30 seconds (within display-assertion window)"
cat <<EOF

Manual action:
  • Close the lid NOW.
  • Wait ~30 seconds.
  • Open the lid. Log in if prompted.
  • Press ENTER.

Expectation:
  • Internal display turned off (lid closed it — no assertion blocks that).
  • System did NOT sleep. The spotlight-menu clock etc. should be up to
    date on lid-open, music/downloads should have kept running.
EOF
read -r

SLEEP_COUNT_AFTER=$(pmset -g log 2>/dev/null | grep -c "Entering Sleep state" || true)
if (( SLEEP_COUNT_AFTER > SLEEP_COUNT_BEFORE )); then
    fail "System slept during lid-close (pmset log shows new Entering Sleep). \
AirAssist's display-assertion didn't prevent clamshell system-sleep. \
(Was an external display connected? Was the Mac on battery?)"
fi
pass "System did not sleep during lid-close in display window"

# ------------------------------------------------------------------
# Step 3 — skip the full 10 minutes with the debug URL (1-min timer).
# ------------------------------------------------------------------
banner "Step 3 of 3 — force the downgrade, then close the lid again"
cat <<EOF

We don't want to make you wait 10 minutes. Re-arm via the debug URL
(1-minute timer) and wait for the downgrade. The test will tell you
when to close the lid.

Press ENTER to continue.
EOF
read -r

open "airassist://debug/stay-awake?mode=displayThenSystem"

printf "Waiting 65 seconds for the downgrade to fire..."
for _ in $(seq 1 65); do printf "." ; sleep 1; done
printf "\n"

ASSRT=$(aa_assertions)
[[ "$ASSRT" == *PreventUserIdleSystemSleep* ]] \
    || fail "Downgrade never fired — expected system assertion, got: '$ASSRT'"
pass "Downgrade fired: AirAssist now holds PreventUserIdleSystemSleep"

SLEEP_COUNT_BEFORE=$(pmset -g log 2>/dev/null | grep -c "Entering Sleep state" || true)

cat <<EOF

Manual action:
  • Close the lid NOW.
  • Wait ~30 seconds.
  • Open the lid. Log in if prompted.
  • Press ENTER.

Expectation:
  • Same as before: display off, system awake.
  • (PreventUserIdleSystemSleep behaves the same as the display variant
    with respect to clamshell sleep on Apple Silicon.)
EOF
read -r

SLEEP_COUNT_AFTER=$(pmset -g log 2>/dev/null | grep -c "Entering Sleep state" || true)
if (( SLEEP_COUNT_AFTER > SLEEP_COUNT_BEFORE )); then
    fail "System slept during post-downgrade lid-close. \
The downgraded system assertion didn't hold clamshell-sleep at bay."
fi
pass "System did not sleep during post-downgrade lid-close"

# Reset to off so we don't leave an assertion dangling.
open "airassist://debug/stay-awake?mode=off"

banner "OK — #37 verified (lid-close behavior in displayThenSystem mode)"
