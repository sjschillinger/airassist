# homebrew-airassist (template)

This folder is a **scaffold**, not a live Homebrew tap. Copy its contents
into a separate public GitHub repo named `homebrew-airassist` (the
`homebrew-` prefix is how `brew tap` discovers it), then users can
install Air Assist with:

```bash
brew install --cask sjschillinger/airassist/airassist
```

## One-time setup

1. Create a **new public repo** on GitHub named
   `homebrew-airassist` under the same account that hosts the main
   AirAssist repo. The repo name **must** start with `homebrew-`.
2. Copy this whole folder's contents into the repo root:
   ```
   Casks/airassist.rb
   README.md
   ```
   (The `Casks/` directory name is mandatory — Homebrew looks there.)
3. Commit, push.
4. Tap it locally to smoke-test:
   ```bash
   brew tap sjschillinger/airassist
   brew install --cask airassist
   ```

## Per-release update flow

Every time the main repo publishes a new release:

1. Download the zip from the GitHub Release and compute its SHA256:
   ```bash
   shasum -a 256 AirAssist-1.2.3.zip
   ```
   (Or just read `SHA256SUMS.txt` attached to the release.)
2. In `Casks/airassist.rb`, bump `version` and `sha256` to match.
3. Commit, push. That's it.

Users who have already run `brew install --cask airassist` get the
update via `brew upgrade` (or `brew upgrade --cask airassist`).

See `docs/releasing.md` in the main AirAssist repo for the full flow.

## Why a separate repo?

Homebrew taps are conventionally their own repos — it keeps the cask
definition versioned independently from the app, and lets you push
formula fixes (e.g. a broken SHA, a missed `zap` path) without cutting
a new app release. `brew tap` only works on repos whose name starts
with `homebrew-`.
