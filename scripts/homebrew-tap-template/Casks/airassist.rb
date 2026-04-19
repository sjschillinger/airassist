# Homebrew cask for Air Assist.
#
# Bump `version` + `sha256` on every release. The rest is static.
# SHA256 comes from SHA256SUMS.txt attached to the GitHub Release
# (or `shasum -a 256 AirAssist-<version>.zip`).

cask "airassist" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/sjschillinger/airassist/releases/download/v#{version}/AirAssist-#{version}.zip"
  name "Air Assist"
  desc "Menu-bar thermal monitor and workload governor for fanless MacBook Air"
  homepage "https://github.com/sjschillinger/airassist"

  # Air Assist is Apple Silicon only and targets recent macOS. Keep these
  # in sync with project.yml's deployment target.
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  # We ship ad-hoc signed builds (no $99/yr Developer ID). Homebrew
  # downloads via curl, which does NOT set com.apple.quarantine, so
  # Gatekeeper stays quiet on install. No `xattr` dance needed for
  # brew-installed copies.
  app "AirAssist.app"

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
