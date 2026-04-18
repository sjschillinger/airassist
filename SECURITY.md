# Security policy

## Reporting a vulnerability

Please **do not open a public GitHub issue** for security problems.

Instead, use GitHub's private
[Security Advisories](https://github.com/TODO_USER/airassist/security/advisories/new)
form, or email the maintainer directly:

- **Contact:** sjschillinger@gmail.com
- **Subject line:** `[airassist-security] <short description>`

We will acknowledge reports within **72 hours** and aim to publish a
fix or a documented workaround within **14 days** for high-severity
issues.

## Scope

Air Assist is a menu-bar thermal monitor and per-process duty-cycle
throttler. Reports we want to see:

- Ways to crash Air Assist such that a paused (`SIGSTOP`) process stays
  paused after Air Assist exits. This is the single most important
  failure mode.
- Ways to escalate privilege via Air Assist, or to trick Air Assist
  into SIGSTOPing a process the user did not authorize (for example,
  a root-owned process, an Apple-protected process, or a process owned
  by another user).
- Bypasses of the foreground-app duty floor that would let a remote
  process reduce the responsiveness of the user's current work.
- Supply-chain issues: compromised release artifacts, unsafe CI
  configurations, signing gaps.

Out of scope:

- Anything that requires the user to already be running a malicious
  binary as their own user with full Terminal access — Air Assist
  doesn't claim to harden against that attacker.
- Feature requests filed as "security issues."

## Responsible disclosure

If you are a security researcher, we will credit you in the release
notes for the fix unless you prefer to remain anonymous. Please give
us a reasonable fix window before publishing details.

Thank you.
