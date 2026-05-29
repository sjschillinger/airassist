#!/usr/bin/env bash
# package-release.sh — Build a Release .app, ad-hoc sign it, and wrap it in a
# UDZO DMG with a /Applications symlink for drag-to-install.
#
# Usage:
#   ./package-release.sh              # build + DMG into ./Release/
#   ./package-release.sh --clean      # remove ./Release/ first, then build
#
# Prerequisites:
#   - Xcode (xcodebuild, codesign, hdiutil)
#   - The project is already configured (project.yml → xcodegen generate if needed)
#
# Output (in ./Release/):
#   AirAssist-<version>.dmg    UDZO read-only compressed disk image
#   AirAssist.app              The ad-hoc signed app bundle
#   SHA256SUMS.txt             SHA-256 checksum for the DMG

set -euo pipefail

CLEAN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --clean) CLEAN=true ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "${ROOT}"

RELEASE_DIR="${ROOT}/Release"

# --- Clean -------------------------------------------------------------------

if $CLEAN; then
  echo "→ Cleaning ${RELEASE_DIR}"
  rm -rf "${RELEASE_DIR}"
fi

# --- Build -------------------------------------------------------------------

echo "→ Building Release configuration…"
xcodebuild \
  -project AirAssist.xcodeproj \
  -scheme AirAssist \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  build 2>&1 | tail -5

# Locate the built .app (xcodebuild puts it under DerivedData)
DERIVED_DATA=$(xcodebuild -project AirAssist.xcodeproj -scheme AirAssist -showBuildSettings 2>/dev/null \
  | grep -m1 'BUILT_PRODUCTS_DIR' | awk -F= '{print $2}' | xargs)
APP_SRC="${DERIVED_DATA}/AirAssist.app"

if [ ! -d "${APP_SRC}" ]; then
  echo "✖ built .app not found at ${APP_SRC}" >&2
  exit 1
fi

VERSION=$(defaults read "${APP_SRC}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
echo "✓ Build complete — Air Assist ${VERSION}"

# --- Stage -------------------------------------------------------------------

rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"

echo "→ Copying .app to ${RELEASE_DIR}"
cp -R "${APP_SRC}" "${RELEASE_DIR}/"

# --- Sign --------------------------------------------------------------------

echo "→ Ad-hoc signing (deep)…"
codesign --force --deep --sign - "${RELEASE_DIR}/AirAssist.app"

echo "→ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "${RELEASE_DIR}/AirAssist.app" 2>&1 | tail -3

# --- Package as DMG ----------------------------------------------------------

DMG_NAME="AirAssist-${VERSION}.dmg"
STAGING="${RELEASE_DIR}/dmg-staging"

echo "→ Staging DMG contents…"
mkdir -p "${STAGING}"
cp -R "${RELEASE_DIR}/AirAssist.app" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

echo "→ Creating ${DMG_NAME} (UDZO)…"
hdiutil create \
  -volname "Air Assist" \
  -srcfolder "${STAGING}" \
  -ov \
  -format UDZO \
  "${RELEASE_DIR}/${DMG_NAME}"

rm -rf "${STAGING}"

# --- Checksums ---------------------------------------------------------------

SHA=$(shasum -a 256 "${RELEASE_DIR}/${DMG_NAME}" | cut -d ' ' -f 1)
echo "${SHA}  ${DMG_NAME}" > "${RELEASE_DIR}/SHA256SUMS.txt"

# --- Done --------------------------------------------------------------------

SIZE=$(stat -f%z "${RELEASE_DIR}/${DMG_NAME}")
echo ""
echo "──────────────────────────────────────────────"
echo "✓ Release package ready: ${RELEASE_DIR}/"
echo "  ${DMG_NAME}  ($(numfmt --to=iec "${SIZE}" 2>/dev/null || echo "${SIZE} bytes"))"
echo "  SHA256: ${SHA}"
echo "──────────────────────────────────────────────"
