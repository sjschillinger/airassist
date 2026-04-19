#!/usr/bin/env bash
#
# verify-force-quit-clean.sh — checklist item #38
#
# Asserts that the clean-quit path (Activity Monitor → Force Quit with
# SIGTERM, or ⌘Q from the app menu) releases every throttled PID before
# AirAssist exits. This is different from #17 (hard SIGKILL) — here we
# rely on the in-process signal handlers wired in SafetyCoordinator for
# SIGTERM/SIGINT/SIGHUP/SIGQUIT, which should run `releaseAll()` in the
# handler before the runtime tears down.
#
# The distinction matters because the user's mental model for "Force
# Quit" in Activity Monitor is "stop the app". If we ship it and users
# come away with paused Slacks, they'll review badly even though the
# hard-crash path is fine.
#
# Procedure:
#   1. Rule engine on, 'yes' rule at duty 0.10 (same setup as #16).
#   2. Spawn 'yes' target, confirm it's being cycled.
#   3. Send SIGTERM to AirAssist (equivalent to Activity Monitor →
#      Force Quit's *first* button, which is SIGTERM not SIGKILL).
#   4. Within ~1 second of AirAssist exiting, the target should NOT
#      be in 'T' state — the handler released it before exit.
#   5. Re-run with SIGINT and SIGHUP for belt-and-braces coverage of
#      all signals the handler registers.

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

run_one_case() {
    local sig="$1"  # e.g. TERM, INT, HUP, QUIT
    banner "── case: SIG${sig} ──"

    # AirAssist must be running again for each case. If it was killed
    # by the previous case, ask the user to relaunch.
    if ! pgrep -x AirAssist >/dev/null; then
        cat <<EOF
${YELLOW}AirAssist is not running. Relaunch it, make sure the 'yes'
duty-0.10 rule is still enabled, then press ENTER.${RESET}
EOF
        read -r
    fi
    local AA_PID
    AA_PID=$(pgrep -x AirAssist | head -1)
    pass "AirAssist is running (pid=$AA_PID)"

    # Spawn fresh target
    TARGET_PID=$( (yes > /dev/null & echo $!) )
    sleep 2
    pass "spawned target 'yes' pid=$TARGET_PID"

    # Confirm throttling
    local HITS=0
    for _ in $(seq 1 30); do
        local S
        S=$(ps -o stat= -p "$TARGET_PID" 2>/dev/null | tr -d ' ')
        [[ "$S" == T* ]] && HITS=$((HITS+1))
        sleep 0.05
    done
    [[ "$HITS" -gt 0 ]] || fail "target never SIGSTOPed — rule not firing?"
    pass "target is being duty-cycled"

    banner "sending SIG${sig} to AirAssist..."
    kill "-${sig}" "$AA_PID"
    for _ in $(seq 1 50); do
        pgrep -x AirAssist >/dev/null || break
        sleep 0.1
    done
    if pgrep -x AirAssist >/dev/null; then
        # Some signals (HUP) may not terminate the app if handler absorbs
        # them. Accept "app still alive AND target is released" as a pass.
        :
    fi

    sleep 0.3
    local POST
    POST=$(ps -o stat= -p "$TARGET_PID" 2>/dev/null | tr -d ' ' || echo "X")
    [[ "$POST" != T* ]] || fail "SIG${sig}: target still paused after exit (STAT=$POST)"
    pass "SIG${sig}: target released cleanly (STAT=$POST)"

    kill -CONT "$TARGET_PID" 2>/dev/null || true
    kill        "$TARGET_PID" 2>/dev/null || true
    wait        "$TARGET_PID" 2>/dev/null || true
    TARGET_PID=""
}

banner "verify-force-quit-clean.sh — #38"

cat <<EOF
${YELLOW}Manual setup required:${RESET}
  Same as #16: rule matching 'yes' at duty 0.10, rule engine on.
  Press ENTER when AirAssist is running with the rule active.
EOF
read -r

run_one_case TERM
run_one_case INT
run_one_case HUP
# SIGQUIT may core-dump under debug builds; skip by default. Uncomment
# if/when release builds are being verified:
# run_one_case QUIT

banner "OK — #38 verified across SIGTERM/SIGINT/SIGHUP."
