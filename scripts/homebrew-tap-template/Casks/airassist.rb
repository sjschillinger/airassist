# Homebrew cask for Air Assist.
#
# Bump `version` + `sha256` on every release. The rest is static.
# SHA256 comes from SHA256SUMS.txt attached to the GitHub Release
# (or `shasum -a 256 AirAssist-<version>.zip`).

cask "airassist" do
  version "0.9.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/sjschillinger/airassist/releases/download/v#{version}/AirAssist-#{version}.dmg"
  name "Air Assist"
  desc "Menu-bar thermal monitor and workload governor for fanless Macs, such as MacBook Airs and Neos"
  homepage "https://github.com/sjschillinger/airassist"

  # Air Assist is Apple Silicon only and targets recent macOS. Keep these
  # in sync with project.yml's deployment target (currently macOS 15).
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  # `brew livecheck` and `brew bump-cask-pr` parse GitHub's latest-release
  # tag (e.g. "v0.9.0") and normalize off the leading "v" to produce the
  # next cask version. Matches the tagging convention release.yml expects.
  livecheck do
    url :url
    strategy :github_latest
  end

  # We ship ad-hoc signed builds (no $99/yr Developer ID). Recent
  # Homebrew versions tag cask downloads with `com.apple.quarantine`,
  # which — on macOS Sequoia and newer — causes Gatekeeper to show the
  # "Apple could not verify…" dialog on first launch. We strip the
  # attribute in a postflight so the app opens cleanly on first run,
  # matching the experience users reasonably expect from a brew-
  # installed tool. The signature, bundle contents, and SHA256 are
  # unchanged — this only removes the first-launch quarantine flag,
  # same as a user running `xattr -dr com.apple.quarantine` manually.
  app "AirAssist.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/AirAssist.app"],
                   sudo: false
  end

  # Clean uninstall. `brew uninstall --cask airassist --zap` removes
  # everything below in addition to the .app.
  zap trash: [
    "~/Library/Application Support/AirAssist",
    "~/Library/Caches/com.sjschillinger.airassist",
    "~/Library/Preferences/com.sjschillinger.airassist.plist",
    "~/Library/Saved Application State/com.sjschillinger.airassist.savedState",
    "~/Library/Logs/AirAssist",
  ]
end
