# Releasing Air Assist

End-to-end cut-a-release flow. Intentionally boring — every step is
either a single command or pasting one string.

> **First time shipping?** Read [launch-day.md](launch-day.md) instead.
> It covers the one-time bootstrap (creating the public app + tap
> repos, the first end-to-end install smoke) that doesn't apply once
> you're in steady state.

## What gets shipped

A single `AirAssist-<version>.zip` attached to a GitHub Release, plus a
`SHA256SUMS.txt`. The zip contains an ad-hoc signed `AirAssist.app`.
Users install via:

```bash
brew install --cask sjschillinger/airassist/airassist
```

Homebrew's tap (`homebrew-airassist`) is a **separate public repo**;
see `scripts/homebrew-tap-template/README.md`.

## Why ad-hoc signing, not Developer ID + notarization

This is a **permanent decision for Air Assist**, not a temporary
stopgap to avoid the $99/yr Apple Developer Program fee. The reasoning:

1. **Homebrew already solves Gatekeeper.** `brew install --cask` pulls
   the zip via curl (doesn't set `com.apple.quarantine`) and installs
   into `/Applications`. macOS treats it as a trusted local install.
   Notarization's job is making *direct downloads* smoother — we don't
   distribute that way.
2. **AGPL-3.0 forks are expected.** If the "official" AirAssist is
   notarized under one person's Apple Developer ID, every forker is
   forced either to (a) pay Apple $99/yr themselves or (b) ship an
   "unofficial-feeling" ad-hoc build. Neither is great. By making
   ad-hoc + Homebrew the canonical path, every build — ours and
   forks — stands on the same footing: verifiable source, tap
   provenance, SHA256 pinning.
3. **Source is the trust root.** Notarization means Apple scans your
   binary and vouches for it. For a tool whose selling point is "no
   telemetry, no network, audit it yourself," adding an Apple-vouching
   step is philosophically noisy. Users who want stronger assurance
   should read the code and build locally — that's the OSS promise
   and notarization doesn't improve on it.
4. **Reproducibility.** Notarized binaries are harder to reproduce
   bit-for-bit (Apple's signature timestamp varies). Ad-hoc builds
   are closer to reproducible, which matters if anyone ever wants to
   supply-chain-verify a release.

Users who download the zip **directly from the GitHub release page**
(instead of via Homebrew) will hit the quarantine flag and need to run
`xattr -dr com.apple.quarantine /Applications/AirAssist.app` once. The
README documents this. That friction is intentionally placed on the
direct-download path so Homebrew stays the smooth default.

### When we'd reconsider

Only if one of these becomes true:

- Direct `.dmg` from a website becomes a distribution channel we care
  about
- Casual-user install friction ("macOS says it's damaged") becomes the
  single most common support issue — not "an" issue, *the* issue
- We decide to pursue the Mac App Store, which would separately
  require sandboxing (declined — incompatible with our IOKit
  entitlement)

None of these apply today. The `.github/workflows/release.yml` file
still has a commented-out block for the paid-tier swap in case a
future maintainer changes their mind, but this is a deliberate
position, not a TODO.

## Pre-flight

Before tagging:

1. Bump version:
   - `project.yml`: `CFBundleShortVersionString` + `CFBundleVersion`
   - Regenerate: `xcodegen generate`
2. Update `CHANGELOG.md` — move Unreleased entries under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading.
3. Run the test suite locally:
   ```bash
   xcodebuild -project AirAssist.xcodeproj -scheme AirAssist \
              -destination 'platform=macOS' -configuration Debug \
              CODE_SIGNING_ALLOWED=NO test
   ```
4. Sanity-run the app on the Air (`⌘R` in Xcode). Confirm the menu bar
   icon + popover show correctly.
5. Commit the version bump + changelog: `Release vX.Y.Z`.

## Cutting the tag

```bash
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

This triggers `.github/workflows/release.yml`. It:

1. Archives with ad-hoc signing.
2. Re-signs the exported bundle deep.
3. Zips via `ditto` (preserves xattrs + signature).
4. Computes SHA256, writes `SHA256SUMS.txt`.
5. Creates a **draft** GitHub Release with the zip attached.

**Drafts don't publish automatically** — that's deliberate. Nothing is
public until you click "Publish release" in the GitHub UI.

## Verify the draft

Before publishing:

1. Go to Releases on GitHub. Find the draft.
2. Download `AirAssist-<version>.zip` from the draft.
3. Unzip and launch `AirAssist.app` — confirm it runs.
4. (Optional) Install via the zip + `xattr -dr com.apple.quarantine`
   path to simulate a direct-download user.
5. Copy the SHA256 from `SHA256SUMS.txt` in the release assets.

## Publish

Click **Publish release** in the GitHub UI. The tag and zip are now
public.

## Update the Homebrew tap

In the `homebrew-airassist` repo:

1. Edit `Casks/airassist.rb`:
   - Bump `version "X.Y.Z"`.
   - Paste the new `sha256 "…"` from `SHA256SUMS.txt`.
2. Commit:
   ```
   Update airassist to X.Y.Z
   ```
3. Push. Done — `brew upgrade --cask airassist` will pick it up.

## Rollback

If a release is broken:

1. Unpublish the GitHub Release (turn it back into a draft) or delete
   it entirely. Delete the tag too (`git push --delete origin vX.Y.Z`).
2. Revert the tap's cask change (revert the commit that bumped
   `version` + `sha256`).
3. Cut a patched `vX.Y.(Z+1)`.

Do **not** edit a published release's assets in place — Homebrew
caches by URL, so users who already installed the bad build will not
get the fix unless the version bumps.

## If a future maintainer decides to switch to Developer ID + notarization

(See the "Why ad-hoc signing" section above for why this isn't the
current plan. This section exists so the mechanical swap is documented
if someone *does* change their mind.)

Swap in:

- `apple-actions/import-codesign-certs@v2` before the Archive step
- Replace `CODE_SIGN_IDENTITY=-` with the real Developer ID identity
- After the re-sign step, add:
  ```
  xcrun notarytool submit AirAssist-<ver>.zip \
    --apple-id … --team-id … --password … --wait
  xcrun stapler staple build/export/AirAssist.app
  ```
  (and re-zip after stapling)
- Drop the `xattr` note from README + cask

Everything else stays the same.
