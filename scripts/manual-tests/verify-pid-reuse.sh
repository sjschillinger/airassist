#!/usr/bin/env bash
#
# verify-pid-reuse.sh — checklist item #19
#
# Asserts that AirAssist's exit-watcher (kqueue EVFILT_PROC NOTE_EXIT,
# registered per PID in ProcessThrottler.installExitWatcher) removes a
# throttled PID from its tracking the moment the original process dies.
#
# The danger: macOS recycles PIDs. If we throttle pid 12345 (Slack),
# Slack exits, the kernel later hands pid 12345 to a different program
# (say `sshd-keygen-wrapper`), and our cycler is still toggling 12345 —
# we'd SIGSTOP something unrelated. The exit-watcher closes that window
# by cancelling the throttle entry on the original exit.
#
# Procedure:
#   1. Confirm the 'yes' duty-0.10 rule is active.
#   2. Spawn target A, confirm it's being duty-cycled.
#   3. Kill target A. Note its PID.
#   4. Within AirAssist's control-loop interval, the throttler's
#      internal tracking should drop that PID. We observe this
#      indirectly via:
#        - absence of pid in `ps` (it's dead), AND
#        - absence of any ongoing -CONT / -STOP traffic against that
#          number (hard to observe without dtrace, so we rely on a
#          follow-up re-spawn: a new process that happens to get the
#          same PID should NOT be throttled without a new rule match).
#
# Because PID recycling is non-deterministic we can't always force pid
# collision in a short script. So the script does a weaker check:
# after target A exits, AirAssist's throttle-list (visible in the menu
# bar popover) no longer lists the dead PID. The user confirms that
# visually. This matches the pre-launch verification rubric in
# LAUNCH_CHECKLIST.md — "make the failure visible, document the check,
# don't pretend it's automated."

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

banner "verify-pid-reuse.sh — #19"

pgrep -x AirAssist >/dev/null || fail "AirAssist is not running."
pass "AirAssist is running"

cat <<EOF
${YELLOW}Manual setup required:${RESET}
  Same setup as #16: rule matching 'yes' at duty 0.10, rule engine on.
  Open the AirAssist menu bar dropdown and keep the 'Throttling' section
  visible throughout.
  Press ENTER when ready.
EOF
read -r

# --- Spawn target A
TARGET_PID=$( (yes > /dev/null & echo $!) )
sleep 2
pass "spawned target A pid=$TARGET_PID"

# --- Confirm visibility in the throttler
cat <<EOF

${YELLOW}Manual observation required:${RESET}
  You should now see 'yes' (pid $TARGET_PID) listed under Throttling
  in the AirAssist menu bar. Confirm this, then press ENTER.
  (If it never appears, the rule isn't firing — fix that before
  re-running #19.)
EOF
read -r

# --- Kill target A and watch it disappear from the list
banner "killing target A (pid=$TARGET_PID) — watch the menu bar list"
kill -CONT "$TARGET_PID" 2>/dev/null || true
kill        "$TARGET_PID" 2>/dev/null || true
wait        "$TARGET_PID" 2>/dev/null || true
TARGET_PID=""

cat <<EOF

${YELLOW}Manual observation required:${RESET}
  Within ~1–2 seconds, the 'yes' entry should disappear from the
  Throttling list in the AirAssist menu bar.

  If it disappeared: PASS — exit-watcher is working, PID is released.
  If it lingered for many seconds: FAIL — exit-watcher regression.

  Press ENTER if passed, or Ctrl-C to abort.
EOF
read -r
pass "exit-watcher removed dead PID from throttler (user-confirmed)"

# --- Optional collision attempt
cat <<EOF

${YELLOW}Optional — PID-collision attempt:${RESET}
  Spawn a *different* short-lived process ('sleep 60') and watch
  whether it appears in the Throttling list without its own rule
  match. It should NOT. This is best-effort — macOS won't always
  hand you the same PID back.

  Press ENTER to skip, or run manually: 'sleep 60 &; pgrep -n sleep'
  and confirm the new PID is NOT throttled.
EOF
read -r

banner "OK — #19 verified (exit-watcher clears throttler state on PID death)."
