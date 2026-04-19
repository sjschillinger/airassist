#!/usr/bin/env bash
#
# verify-crash-recovery.sh — checklist item #17
#
# Asserts that AirAssist's dead-man's-switch recovery path works end to
# end: if the app is killed (SIGKILL, not a clean quit) while processes
# are paused, the *next* launch reads the inflight-PID file and SIGCONTs
# them before arming anything new.
#
# The recovery path lives in SafetyCoordinator.recoverOnLaunch() and
# reads ~/Library/Application Support/AirAssist/inflight.json. Without
# this test there's no proof that what ships matches what the README
# promises users ("a hard crash won't leave you with a permanently
# paused process").
#
# Procedure:
#   1. Launch AirAssist, confirm a target 'yes' process is being
#      SIGSTOPed on a duty cycle (reuses the rule from #16).
#   2. `kill -9` the AirAssist PID while the target happens to be in
#      the 'T' state (verified via `ps`).
#   3. Confirm the target is stuck in 'T' — no background cleanup.
#   4. Re-launch AirAssist. Within ~2 seconds the target should return
#      to an R/S state without any user action.
#
# The window between kill and relaunch is the "stuck" gap the README
# section on recovery calls out — we're proving that gap closes on
# relaunch rather than sitting open forever.

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

banner "verify-crash-recovery.sh — #17"

# --- Prereqs
if ! pgrep -x AirAssist >/dev/null; then
    fail "AirAssist is not running. Launch it with the 'yes' duty-0.10 rule enabled and rerun."
fi
pass "AirAssist is running"

cat <<EOF
${YELLOW}Manual setup required:${RESET}
  Same setup as #16: a rule matching executable 'yes' at duty 0.10
  with the rule engine enabled. Press ENTER when ready.
EOF
read -r

# --- Spawn the target
TARGET_PID=$( (yes > /dev/null & echo $!) )
sleep 2  # give AirAssist a tick to notice and start cycling
if ! kill -0 "$TARGET_PID" 2>/dev/null; then
    fail "Could not spawn 'yes' target"
fi
pass "spawned target 'yes' pid=$TARGET_PID"

# --- Confirm throttling is happening
STAT=$(ps -o stat= -p "$TARGET_PID" | tr -d ' ')
banner "current STAT for target: $STAT"
if [[ "$STAT" != T* ]]; then
    # Sample a few times — duty cycle might just have it in R right now.
    HITS=0
    for _ in $(seq 1 30); do
        S=$(ps -o stat= -p "$TARGET_PID" 2>/dev/null | tr -d ' ')
        [[ "$S" == T* ]] && HITS=$((HITS+1))
        sleep 0.05
    done
    [[ "$HITS" -gt 0 ]] || fail "target never observed SIGSTOPed — rule not firing?"
fi
pass "target is being duty-cycled"

# --- Kill AirAssist with SIGKILL (simulates hard crash; bypasses handlers)
AIRASSIST_PID=$(pgrep -x AirAssist | head -1)
banner "killing AirAssist pid=$AIRASSIST_PID with SIGKILL"
kill -9 "$AIRASSIST_PID"
# Wait for process to actually exit
for _ in $(seq 1 40); do
    pgrep -x AirAssist >/dev/null || break
    sleep 0.1
done
pgrep -x AirAssist >/dev/null && fail "AirAssist did not exit"
pass "AirAssist exited"

# --- The target should now be stuck in 'T' (no auto-resume)
sleep 0.5
STUCK=$(ps -o stat= -p "$TARGET_PID" | tr -d ' ')
banner "post-kill STAT for target: $STUCK"
[[ "$STUCK" == T* ]] || fail "expected target stuck in 'T' after crash; got '$STUCK'"
pass "target is stuck paused, as expected before recovery"

# --- Relaunch AirAssist
cat <<EOF

${YELLOW}Manual action required:${RESET}
  Relaunch AirAssist now (Spotlight, Dock, or `open -a AirAssist`).
  Press ENTER *after* you've launched it.
EOF
read -r

# --- Expect the target to return to running state within ~2s
RESUMED=""
for _ in $(seq 1 40); do
    S=$(ps -o stat= -p "$TARGET_PID" 2>/dev/null | tr -d ' ' || echo "X")
    if [[ "$S" != T* ]] && [[ "$S" != "X" ]]; then
        RESUMED="$S"
        break
    fi
    sleep 0.1
done
[[ -n "$RESUMED" ]] || fail "target never resumed after relaunch — recovery path broken"
pass "target resumed (STAT=$RESUMED) after AirAssist relaunch"

banner "OK — #17 verified."
