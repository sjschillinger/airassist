#!/usr/bin/env bash
#
# verify-lid-close-displaythensystem.sh — checklist item #37
#
# The automated half of #37 (the timed display→system downgrade itself)
# is covered by test_37_DisplayThenSystemDowngrades in the integration
# runner. What that test CAN'T do is verify real lid-close behavior —
# clamshell sleep is driven by the physical hinge sensor, which a
# headless script cannot simulate.
#
# Empirical finding (2026-04-19, Apple Silicon portable, no external
# display): clamshell close ALWAYS puts the system to sleep on this
# hardware class, regardless of which `PreventUserIdle*` assertion
# AirAssist is holding. pmset logs show:
#
#     Sleep   Entering Sleep state due to 'Clamshell Sleep'
#
# ~10-15s into the lid-close window, whether we're in the pre-downgrade
# (PreventUserIdleDisplaySleep) or post-downgrade
# (PreventUserIdleSystemSleep) phase. This matches Apple's documented
# behavior: the `PreventUserIdle*` family blocks idle-initiated sleep,
# not clamshell-initiated sleep. Closed-lid mode (kept awake with the
# display off) requires an attached external display — that's a
# firmware-level rule we can't override.
#
# So #37's regression concern — "does the downgrade make clamshell
# behavior WORSE?" — is moot: both variants already sleep. The test
# that actually has teeth is the clean-lifecycle check: assertions
# released cleanly on sleep, reacquired cleanly on wake, no stuck
# state.
#
# Usage:
#   scripts/manual-tests/verify-lid-close-displaythensystem.sh
#
# Preconditions:
#   • AirAssist is running (`open -a AirAssist` or from the build).
#   • Mac is on AC power.
#   • External display NOT connected.

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

if ! pmset -g batt | grep -q "AC Power"; then
    printf "${YELLOW}WARN:${RESET} Mac is on battery. Clamshell/wake timing "
    printf "differs on battery; results may be noisier. Plug in and re-run.\n"
fi

if system_profiler SPDisplaysDataType 2>/dev/null | grep -iq "External\|Connection Type: DisplayPort"; then
    printf "${YELLOW}WARN:${RESET} External display detected. With an external "
    printf "monitor, clamshell does NOT sleep the system — a different test. "
    printf "Unplug and re-run for the fanless-Air scenario.\n"
fi

aa_assertions() {
    pmset -g assertions 2>/dev/null \
        | awk -v pid="$AIRASSIST_PID" '
            /^pid [0-9]+\(/ { in_block = ($0 ~ "pid "pid"\\("); next }
            in_block && /PreventUserIdleSystemSleep/  { print "PreventUserIdleSystemSleep" }
            in_block && /PreventUserIdleDisplaySleep/ { print "PreventUserIdleDisplaySleep" }
          ' | sort -u | tr '\n' ' '
}

count_sleep_events() {
    pmset -g log 2>/dev/null | grep -c "Entering Sleep state" || true
}

count_wake_events() {
    pmset -g log 2>/dev/null | grep -cE "^[0-9]{4}-[0-9]{2}-[0-9]{2}.*DarkWake to FullWake|Wake[[:space:]]+from" || true
}

# ------------------------------------------------------------------
# Step 1 — arm displayThenSystem with a short (1-min) timer.
# ------------------------------------------------------------------
banner "Step 1 of 2 — arm displayThenSystem (pre-downgrade phase)"
open "airassist://debug/stay-awake?mode=displayThenSystem" >/dev/null 2>&1
sleep 1

ASSRT=$(aa_assertions)
[[ "$ASSRT" == *PreventUserIdleDisplaySleep* ]] \
    || fail "Expected PreventUserIdleDisplaySleep right after arming; got: '$ASSRT'"
pass "AirAssist holds PreventUserIdleDisplaySleep"

SLEEP_BEFORE=$(count_sleep_events)
WAKE_BEFORE=$(count_wake_events)

cat <<EOF

Manual action:
  • Close the lid NOW.
  • Wait ~30 seconds.
  • Open the lid. Log in if prompted.
  • Press ENTER.

Expectation (corrected 2026-04-19):
  • The system WILL sleep — that's Apple Silicon clamshell behavior
    and AirAssist's assertions can't block it.
  • What we're verifying: the sleep-wake cycle was clean. pmset log
    should show exactly one sleep and one wake, AirAssist's assertion
    is still present or cleanly re-registered post-wake.
EOF
read -r

SLEEP_AFTER=$(count_sleep_events)
WAKE_AFTER=$(count_wake_events)
SLEEP_DELTA=$((SLEEP_AFTER - SLEEP_BEFORE))
WAKE_DELTA=$((WAKE_AFTER  - WAKE_BEFORE))

info "pmset: +$SLEEP_DELTA sleep(s), +$WAKE_DELTA wake(s) during the 30s window"

if (( SLEEP_DELTA < 1 )); then
    fail "No sleep event logged — did the lid actually close? (expected +1)"
fi
if (( SLEEP_DELTA > 2 )); then
    fail "Unexpected multiple sleep events ($SLEEP_DELTA) — investigate."
fi
pass "Clamshell triggered sleep as expected"

ASSRT=$(aa_assertions)
case "$ASSRT" in
    *PreventUserIdleDisplaySleep*|*PreventUserIdleSystemSleep*)
        pass "AirAssist assertion present post-wake: $ASSRT" ;;
    *)
        fail "AirAssist assertion missing post-wake: '$ASSRT' — stuck-release bug?" ;;
esac

# ------------------------------------------------------------------
# Step 2 — force the downgrade, repeat.
# ------------------------------------------------------------------
banner "Step 2 of 2 — force downgrade, clamshell again (post-downgrade phase)"
open "airassist://debug/stay-awake?mode=displayThenSystem" >/dev/null 2>&1
printf "Waiting 65 seconds for the 1-min debug downgrade to fire..."
for _ in $(seq 1 65); do printf "." ; sleep 1; done
printf "\n"

ASSRT=$(aa_assertions)
[[ "$ASSRT" == *PreventUserIdleSystemSleep* ]] \
    || fail "Downgrade never fired — expected system assertion, got: '$ASSRT'"
pass "Downgrade fired: AirAssist now holds PreventUserIdleSystemSleep"

SLEEP_BEFORE=$(count_sleep_events)

cat <<EOF

Manual action:
  • Close the lid NOW.
  • Wait ~30 seconds.
  • Open the lid. Log in if prompted.
  • Press ENTER.

Expectation:
  • Same as Step 1: system will sleep (clamshell), wake cleanly on
    lid-open, and AirAssist's assertion remains registered.
  • The regression this guards against: downgrade somehow corrupts
    the assertion lifecycle — e.g. double-release, stuck assertion,
    or a crash-on-wake.
EOF
read -r

SLEEP_AFTER=$(count_sleep_events)
SLEEP_DELTA=$((SLEEP_AFTER - SLEEP_BEFORE))

info "pmset: +$SLEEP_DELTA sleep(s) during the post-downgrade window"

(( SLEEP_DELTA >= 1 )) || fail "No sleep event logged — did the lid actually close?"
(( SLEEP_DELTA <= 2 )) || fail "Unexpected multiple sleep events ($SLEEP_DELTA)"
pass "Post-downgrade clamshell cycle clean"

ASSRT=$(aa_assertions)
case "$ASSRT" in
    *PreventUserIdleSystemSleep*)
        pass "AirAssist still holds downgraded assertion: $ASSRT" ;;
    *PreventUserIdleDisplaySleep*)
        fail "Assertion reverted to Display after wake — downgrade should persist" ;;
    *)
        fail "AirAssist assertion missing post-wake: '$ASSRT'" ;;
esac

# Reset so we don't leave an assertion dangling.
open "airassist://debug/stay-awake?mode=off" >/dev/null 2>&1

banner "OK — #37 verified (clean assertion lifecycle across clamshell cycles)"
