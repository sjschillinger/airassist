#!/usr/bin/env bash
#
# verify-stay-awake.sh — checklist item #36
#
# Asserts that each of the four Stay-Awake modes actually affects the
# kernel power assertions reported by `pmset -g assertions`. The enum
# lives in StayAwakeController; the modes map to IOPMAssertionCreate
# calls (PreventUserIdleSystemSleep, PreventUserIdleDisplaySleep,
# plus a timed display-then-system variant).
#
# What we verify per mode:
#   off                 → neither assertion held by AirAssist
#   system              → PreventUserIdleSystemSleep held, display-sleep NOT held
#   display             → PreventUserIdleDisplaySleep held (system sleep
#                         is implicit under display assertion)
#   displayThenSystem   → display assertion held initially, then after
#                         the configured minute-level timeout flips to
#                         system-only. We only verify the *initial*
#                         state here; the timed flip is asserted by
#                         the unit test for StayAwakeController.
#
# The script greps `pmset -g assertions` for AirAssist's PID line and
# parses the held assertion names. No clicking around — the user just
# flips the mode picker in Preferences and presses ENTER between
# checks.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RESET='\033[0m'
banner() { printf "\n${YELLOW}%s${RESET}\n" "$1"; }
pass()   { printf "${GREEN}PASS:${RESET} %s\n" "$1"; }
fail()   { printf "${RED}FAIL:${RESET} %s\n" "$1"; exit 1; }

banner "verify-stay-awake.sh — #36"

AIRASSIST_PID=$(pgrep -x AirAssist | head -1 || true)
[[ -n "$AIRASSIST_PID" ]] || fail "AirAssist is not running."
pass "AirAssist is running (pid=$AIRASSIST_PID)"

# Return the assertion types currently held by AirAssist's PID.
# Empty string means no assertions. Prints space-separated short names.
aa_assertions() {
    # `pmset -g assertions` lists per-process blocks headed by
    # "pid <N>(<proc>):"; we grab the block for our pid and extract
    # any indented PreventUser* lines.
    pmset -g assertions 2>/dev/null \
        | awk -v pid="$AIRASSIST_PID" '
            /^pid [0-9]+\(/ { in_block = ($0 ~ "pid "pid"\\("); next }
            in_block && /PreventUserIdleSystemSleep/ { print "PreventUserIdleSystemSleep" }
            in_block && /PreventUserIdleDisplaySleep/ { print "PreventUserIdleDisplaySleep" }
          ' | sort -u | tr '\n' ' '
}

prompt_mode() {
    local mode="$1"
    cat <<EOF

${YELLOW}Manual action:${RESET}
  In AirAssist Preferences → General → Stay Awake, select:
    ${mode}
  Wait ~1 second for the assertion to update, then press ENTER.
EOF
    read -r
}

# --- Off
prompt_mode "Off"
ASSRT=$(aa_assertions)
if [[ -n "$ASSRT" ]]; then
    fail "Off mode should release all assertions, got: $ASSRT"
fi
pass "Off: no AirAssist-held assertions"

# --- Keep system awake
prompt_mode "Keep system awake"
ASSRT=$(aa_assertions)
[[ "$ASSRT" == *PreventUserIdleSystemSleep* ]] \
    || fail "system mode should hold PreventUserIdleSystemSleep; got: '$ASSRT'"
[[ "$ASSRT" != *PreventUserIdleDisplaySleep* ]] \
    || fail "system mode should NOT hold the display assertion; got: '$ASSRT'"
pass "system mode: PreventUserIdleSystemSleep only"

# --- Keep system & display awake
prompt_mode "Keep system & display awake"
ASSRT=$(aa_assertions)
[[ "$ASSRT" == *PreventUserIdleDisplaySleep* ]] \
    || fail "display mode should hold PreventUserIdleDisplaySleep; got: '$ASSRT'"
pass "display mode: display assertion held"

# --- Display, then system
prompt_mode "Display on, then system only"
ASSRT=$(aa_assertions)
[[ "$ASSRT" == *PreventUserIdleDisplaySleep* ]] \
    || fail "displayThenSystem (initial window) should hold display assertion; got: '$ASSRT'"
pass "displayThenSystem initial: display assertion held"

banner "OK — #36 verified. (The timed display→system flip is covered by the unit test.)"
