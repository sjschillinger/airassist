# Launch Day — bootstrapping the first public release

`docs/releasing.md` describes the steady-state flow for every release
after the first. This file covers the one-time bootstrap: creating
the public repos, cutting v0.9.0, and getting Homebrew working end-
to-end.

Everything here is a sequence of things only the maintainer can do —
the automation in `.github/workflows/release.yml` handles the build
side. Follow it top-to-bottom in one session; the order matters.

## Prerequisites on your Mac

- `gh` authenticated with your GitHub account (`gh auth status`)
- The private repo clean: `git status` reports nothing uncommitted
- Tests green locally:
  ```bash
  xcodebuild -project AirAssist.xcodeproj -scheme AirAssist \
             -destination 'platform=macOS' \
             -only-testing:AirAssistTests test
  ```
- A 15-minute window for the manual smoke below — don't start this on
  the way out the door.

## Step 1 — Pre-flight smoke on the Air

Build + launch the Debug app manually and touch every new 0.9.0 surface.

```bash
pkill -f "AirAssist.app/Contents/MacOS/AirAssist" 2>/dev/null; sleep 0.5
xcodebuild -project AirAssist.xcodeproj -scheme AirAssist \
           -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/AirAssist-*/Build/Products/Debug/AirAssist.app
```

Then drive it by hand. Checklist — each should visibly do the right
thing, not just "not crash":

- [ ] Menu-bar icon appears.
- [ ] Popover opens; sparklines and top-processes panel render.
- [ ] Preferences → Throttling → **Advanced** section appears when a
      governor mode is active. Toggle **Throttle only when on battery**
      on, unplug the charger, verify the reason string changes from
      "Idle · on AC" to the normal armed/throttling text within ~1s.
      Plug back in, verify it swings back.
- [ ] Preferences → Throttling → Advanced → toggle **Factor in the OS
      thermal state** off and back on. (Effect is subtle — the point
      is the toggle persists across quit/relaunch.)
- [ ] Preferences → General → **Stay Awake** → pick "Keep system &
      display awake". "When the display sleeps → Release Stay Awake"
      row appears. Toggle it on. `pmset -g assertions | grep AirAssist`
      shows an assertion is held. Close the lid (or `pmset
      displaysleepnow`). Assertion drops. Open the lid. Assertion
      comes back.
- [ ] `open airassist://pause?duration=30s` followed by `open
      airassist://resume` — both work, popover status reflects each.
- [ ] Quit with ⌘Q while governor is actively throttling a test
      process (`yes > /dev/null &`). The quit-confirmation dialog
      appears and ⌘Q releases the paused PIDs.

Any checklist item failing → fix before tagging. Don't ship a v0.9.0
that fails its own README.

## Step 2 — Create the public app repo

```bash
# From the private repo root
./scripts/publish.sh 0.9.0           # dry run, inspects staging dir
./scripts/publish.sh 0.9.0 --commit  # writes into ../airassist-public
```

The allowlist-filtered public working tree lives at
`$PUBLIC_REPO_DIR` (default `../airassist-public`). It will be a
git repo with one commit ("Release 0.9.0") and a local `v0.9.0` tag.

Create the remote and push:

```bash
cd ../airassist-public
gh repo create sjschillinger/airassist --public \
    --description "Menu-bar thermal monitor + workload governor for fanless Macs, such as MacBook Airs and Neos" \
    --source . --push
git push origin v0.9.0   # push the tag — triggers release.yml
```

`release.yml` will now run on the public repo's `macos-15` runner.
Watch it: `gh run watch --repo sjschillinger/airassist`. Expected
runtime ~8–12 minutes.

If the run fails, read the log and fix. **Do not publish the draft
release that results from a failed run** — delete it and fix the
tag.

## Step 3 — Verify and publish the draft release

The workflow creates a **draft** release. Before publishing:

1. Open the draft in the GitHub UI.
2. Download `AirAssist-0.9.0.zip` to a fresh location.
3. Verify the SHA matches `SHA256SUMS.txt`:
   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```
4. Unzip to `/tmp`, run `xattr -dr com.apple.quarantine
   /tmp/AirAssist.app`, launch. It should behave identically to the
   Debug build.
5. Copy the SHA256 for the next step.
6. Click **Publish release** in the GitHub UI.

Once published, `/releases/latest` resolves and the in-app update
checker will see v0.9.0. (It won't nudge you about it — the checker
only nudges when the tag is *newer* than the running version. But
it proves the endpoint works.)

## Step 4 — Create the Homebrew tap

```bash
mkdir -p ~/code/homebrew-airassist && cd ~/code/homebrew-airassist
git init
cp -R ~/AirAssist/scripts/homebrew-tap-template/. .
```

Edit `Casks/airassist.rb`:

- `version` is already `0.9.0` — leave it.
- Replace the `sha256 "0000..."` placeholder with the real SHA from
  step 3.

Commit and create the public tap repo:

```bash
git add -A
git commit -m "Initial tap: airassist 0.9.0"
gh repo create sjschillinger/homebrew-airassist --public \
    --description "Homebrew cask tap for Air Assist" \
    --source . --push
```

## Step 5 — End-to-end install smoke

On any Apple Silicon Mac with Homebrew:

```bash
brew untap sjschillinger/airassist 2>/dev/null || true   # clean slate
brew install --cask sjschillinger/airassist/airassist
```

Homebrew should download the zip, verify the SHA, install into
`/Applications/AirAssist.app`. Launch from Launchpad — no
"damaged / can't be opened" dialog, menu bar icon appears.

```bash
brew uninstall --cask airassist --zap   # verify clean removal
```

Zap should clear `~/Library/Application Support/AirAssist`,
caches, preferences, saved state, logs. Verify with `ls` on those
paths.

## Step 6 — Announce (optional, you control the tempo)

- Update the private repo's `MEMORY.md` / personal notes with the
  launch date.
- Post to wherever you want to post.
- Watch `gh issue list --repo sjschillinger/airassist` for the first
  bug reports.

## If something goes wrong mid-bootstrap

- **Failed release.yml run** — delete the tag on the public repo
  (`git push --delete origin v0.9.0`), delete the draft release in
  the UI, fix the problem, re-run the publish script, re-push.
- **Wrong SHA in the cask** — commit the fix to the tap repo. No
  version bump needed for a same-day SHA correction if the underlying
  zip hasn't changed.
- **App launches but behaves differently than Debug** — almost
  always a Release-config optimizer issue. Archive locally
  (`xcodebuild … archive`) and reproduce before blaming the runner.

## After launch

All subsequent releases follow `docs/releasing.md` — this file is
for the one-time bootstrap only. You can delete it if it becomes
stale, but keeping it around makes "how did we set this up" a
`git log` rather than an archaeology dig.
