#!/bin/bash
# airassist-rescue.command
# =======================
#
# Standalone rescue binary for AirAssist users. Double-clicking this file
# in Finder SIGCONTs every process AirAssist had paused when it last ran,
# then self-destructs the inflight file so launching AirAssist again
# starts from a clean slate.
#
# **When to run this:**
#   - AirAssist crashed and some app (Chrome, Xcode, a video encode) is
#     now unresponsive or stuck at 0% CPU with no visible reason.
#   - You uninstalled AirAssist and forgot to release your rules first —
#     those processes are still frozen.
#   - You're troubleshooting and want to hard-reset the pause state.
#
# **How it works:**
#   AirAssist writes every paused PID to
#   ~/Library/Application Support/AirAssist/inflight.json as it cycles
#   SIGSTOP/SIGCONT. If AirAssist exits cleanly it empties that file.
#   If it didn't, this script reads the file, sends SIGCONT to every
#   listed pid, and removes the file.
#
# **Safety:**
#   - Only signals pids owned by the current user (kill(2) enforces this).
#   - Skips pids outside the valid Darwin range (1–999999).
#   - ESRCH ("no such process") is treated as success — common, harmless.
#   - Does not require sudo. Never asks for a password.
#   - Stock macOS only: bash + /usr/bin/python3, no Homebrew required.

set -euo pipefail

INFLIGHT="$HOME/Library/Application Support/AirAssist/inflight.json"

if [[ ! -f "$INFLIGHT" ]]; then
    echo "airassist-rescue: no inflight file at"
    echo "  $INFLIGHT"
    echo "Either AirAssist exited cleanly or has never paused a process."
    echo "Nothing to do."
    # When launched via Finder double-click, keep the window open so the
    # user can read the output before Terminal auto-closes.
    if [[ -t 0 ]]; then
        read -r -p "Press Return to close this window…"
    fi
    exit 0
fi

echo "airassist-rescue: found inflight file at"
echo "  $INFLIGHT"
echo

# Parse the JSON with stock python3 (ships with macOS since 10.15 via
# the XCode CLT stub, and is present on every supported macOS target).
# The python3 stub prompts for CLT install if it's never been used —
# we use /usr/bin/env python3 as a fallback for machines that already
# have any python3 on PATH (Homebrew, pyenv, etc.).
PIDS=$(
    /usr/bin/python3 - <<'PYEOF' "$INFLIGHT" 2>/dev/null || \
    /usr/bin/env python3 - <<'PYEOF' "$INFLIGHT"
import json, sys
try:
    with open(sys.argv[1], 'rb') as f:
        data = json.load(f)
    pids = data.get('pids', [])
    for p in pids:
        if isinstance(p, int) and 1 < p < 1_000_000:
            print(p)
except Exception:
    pass
PYEOF
)

if [[ -z "$PIDS" ]]; then
    echo "airassist-rescue: no valid pids in inflight file; removing it."
    rm -f "$INFLIGHT"
    if [[ -t 0 ]]; then
        read -r -p "Press Return to close this window…"
    fi
    exit 0
fi

RESUMED=0
SKIPPED=0
while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if kill -CONT "$pid" 2>/dev/null; then
        RESUMED=$((RESUMED + 1))
        echo "  SIGCONT pid=$pid → resumed"
    else
        SKIPPED=$((SKIPPED + 1))
        echo "  SIGCONT pid=$pid → skipped (process already gone, or not ours)"
    fi
done <<< "$PIDS"

rm -f "$INFLIGHT"

echo
echo "airassist-rescue: resumed $RESUMED process(es), skipped $SKIPPED."
echo "The inflight file has been removed. AirAssist will start fresh next launch."

if [[ -t 0 ]]; then
    echo
    read -r -p "Press Return to close this window…"
fi
