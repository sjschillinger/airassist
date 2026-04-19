#!/usr/bin/env bash
#
# Runs every manual-test script in sequence. Intended to be run before
# tagging a release — any single failure blocks the tag.
#
# Scripts must exit 0 on pass, nonzero on fail. Any script requiring
# interactive setup will prompt; run-all respects that and will pause
# until the user presses ENTER. If you want a fully automated run,
# add scripts that don't need setup.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS=(
    verify-sigstop-lands.sh       # #16
    verify-crash-recovery.sh      # #17
    verify-sleep-wake.sh          # #18
    verify-pid-reuse.sh           # #19
    verify-stay-awake.sh          # #36
    verify-force-quit-clean.sh    # #38
)

FAILED=()
for s in "${SCRIPTS[@]}"; do
    printf "\n========================================\n"
    printf "Running %s\n" "$s"
    printf "========================================\n"
    if ! "$HERE/$s"; then
        FAILED+=("$s")
    fi
done

printf "\n========================================\n"
if [[ ${#FAILED[@]} -eq 0 ]]; then
    printf "All manual tests passed.\n"
    exit 0
fi
printf "Failed: %s\n" "${FAILED[*]}"
exit 1
