# Manual tests

Runnable shell scripts for the safety / correctness checks listed in
`LAUNCH_CHECKLIST.md` that can't be unit-tested (require AirAssist to
be running, involve real SIGSTOP, observe sleep/wake, etc).

The goal: "we tested this" means the same thing in 6 months as it
does today. Each script:

- Echoes what it's about to do
- Sets up the scenario
- Asserts the expected state
- Cleans up
- Exits 0 on pass, 1 on fail

Run one-off:

```bash
./scripts/manual-tests/<name>.sh
```

Run the whole suite (add scripts to `run-all.sh` as they land):

```bash
./scripts/manual-tests/run-all.sh
```

## Adding a new test

Follow the shape of `verify-sigstop-lands.sh`:

1. Set `set -euo pipefail` at the top
2. Print a one-line banner of what's being tested
3. Explain the setup prerequisites (e.g. "AirAssist must be running
   and the rule engine must be enabled")
4. Do the setup
5. Assert with clear pass/fail output
6. Clean up via a trap so interrupted runs don't leak
7. Exit with correct status

## Checklist cross-reference

| Script                        | Checklist item |
| ----------------------------- | -------------- |
| `verify-sigstop-lands.sh`     | #16            |
| `verify-crash-recovery.sh`    | #17            |
| `verify-sleep-wake.sh`        | #18            |
| `verify-pid-reuse.sh`         | #19            |
| `verify-stay-awake.sh`        | #36            |
| `verify-force-quit-clean.sh`  | #38            |
