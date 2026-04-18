# Releasing Air Assist

End-to-end cut-a-release flow. Intentionally boring — every step is
either a single command or pasting one string.

## What gets shipped

A single `AirAssist-<version>.zip` attached to a GitHub Release, plus a
`SHA256SUMS.txt`. The zip contains an ad-hoc signed `AirAssist.app`.
Users install via:

```bash
brew install --cask TODO_USER/airassist/airassist
```

Homebrew's tap (`homebrew-airassist`) is a **separate public repo**;
see `scripts/homebrew-tap-template/README.md`.

## Why ad-hoc signing, not Developer ID

$99/yr avoided for now. Homebrew downloads via curl, which doesn't set
`com.apple.quarantine`, so Gatekeeper doesn't block ad-hoc builds
installed that way. Users who download the zip directly from the
release page need to run `xattr -dr com.apple.quarantine /Applications/AirAssist.app`
once. README says so.

Upgrading to paid tier later is a workflow edit, not a rearchitecture —
see the comment block at the top of `.github/workflows/release.yml`.

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

## When we upgrade to paid Developer ID

(For future-me.) Swap in:

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
