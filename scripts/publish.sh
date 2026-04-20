#!/usr/bin/env bash
# publish.sh — export an allowlisted snapshot of this (private) repo into a
# sibling (public) repo directory. The allowlist below is the *only* list
# of paths that can make it into public content; anything else in the
# working tree is silently dropped, and the script errors if there are
# unexpected top-level files so we never blindly publish something new.
#
# Usage:
#   ./scripts/publish.sh <version>               # dry run — preview only
#   ./scripts/publish.sh <version> --commit      # also commit in the public repo
#   ./scripts/publish.sh <version> --commit --push
#
# Configuration:
#   PUBLIC_REPO_DIR  absolute path to the public repo checkout. Override
#                    via env var; defaults to ../airassist-public.
#
# Safety:
#   - allowlist-based: paths NOT listed are dropped
#   - forbidden-string scan on the output before anything leaves the host
#   - never force-pushes
#   - never deletes anything in the public repo it can't recreate
#
# The private repo's git history never leaves this machine. The public
# repo gets a fresh commit per release tag.

set -euo pipefail

# --- Configuration ---------------------------------------------------------

PUBLIC_REPO_DIR="${PUBLIC_REPO_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/airassist-public}"

# Explicit allowlist. Each entry is a path relative to the private repo
# root. Directories are copied recursively. If an entry doesn't exist
# the script fails loudly.
ALLOWLIST=(
  "AirAssist"
  "AirAssistTests"
  # AirAssistRescue: helper binary the main app depends on (safety LaunchAgent).
  # Omitting it breaks `xcodegen generate` on the public repo.
  "AirAssistRescue"
  # Integration + UI test harnesses are referenced by project.yml targets and
  # by the AirAssist scheme. Drop them and xcodegen fails on the public repo.
  "AirAssistIntegrationTests"
  "AirAssistUITests"
  "AirAssist.xcodeproj"
  "project.yml"
  ".gitignore"
  ".github/workflows"
  ".github/ISSUE_TEMPLATE"
  ".github/pull_request_template.md"
  "LICENSE"
  "README.md"
  "CHANGELOG.md"
  "CONTRIBUTING.md"
  "CODE_OF_CONDUCT.md"
  "SECURITY.md"
  "NON_AIR_ROADMAP.md"
  "docs"
  "scripts/install-hooks.sh"
  "scripts/hooks"
)

# Forbidden strings — scanned on the *output* tree as a last line of
# defence. Matches the pre-commit hook.
FORBIDDEN_PATTERN='App[[:space:]]*Tamer|AppTamer|TG[[:space:]]*Pro|TGPro|iStat[[:space:]]*Menus|Macs[[:space:]]*Fan[[:space:]]*Control|BGHUDAppKit|BBRLogger|BBRLayout|BBRUpdater'

# --- Args ------------------------------------------------------------------

if [ $# -lt 1 ]; then
  echo "usage: $0 <version> [--commit] [--push]" >&2
  exit 1
fi
VERSION="$1"; shift
DO_COMMIT=false
DO_PUSH=false
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) DO_COMMIT=true ;;
    --push)   DO_PUSH=true ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done
if $DO_PUSH && ! $DO_COMMIT; then
  echo "✖ --push requires --commit" >&2
  exit 1
fi

PRIVATE_ROOT=$(git rev-parse --show-toplevel)
cd "${PRIVATE_ROOT}"

# --- Sanity checks ---------------------------------------------------------

# Refuse to publish if the private repo has uncommitted changes — we only
# publish what's committed, never a dirty tree.
if ! git diff-index --quiet HEAD --; then
  echo "✖ working tree is dirty. commit or stash before publishing." >&2
  exit 1
fi

# Every allowlist entry must exist.
for path in "${ALLOWLIST[@]}"; do
  if [ ! -e "${path}" ]; then
    echo "✖ allowlist entry missing from private repo: ${path}" >&2
    exit 1
  fi
done

# Warn (don't fail) on unexpected top-level entries. Useful if you add a
# new file that should probably be on the allowlist.
echo "→ Scanning top-level entries not on allowlist…"
# macOS still ships bash 3.2 — no associative arrays. Use a sorted newline
# list + fgrep for the lookup instead.
known_top_level=$(printf '%s\n' "${ALLOWLIST[@]}" | awk -F/ '{print $1}' | sort -u)
while IFS= read -r entry; do
  name=$(basename "${entry}")
  case "${name}" in
    .git|.DS_Store) continue ;;
  esac
  if ! printf '%s\n' "${known_top_level}" | grep -qxF "${name}"; then
    echo "   · skipping (not on allowlist): ${name}"
  fi
done < <(find . -mindepth 1 -maxdepth 1)

# --- Stage output ----------------------------------------------------------

STAGE=$(mktemp -d -t airassist-publish.XXXXXX)
trap 'rm -rf "${STAGE}"' EXIT

echo "→ Staging allowlisted paths into ${STAGE}"
for path in "${ALLOWLIST[@]}"; do
  mkdir -p "${STAGE}/$(dirname "${path}")"
  cp -R "${path}" "${STAGE}/${path}"
done

# --- Forbidden-string scan on the staged output ----------------------------

echo "→ Scanning staged output for forbidden references…"
if violations=$(grep -IErln "${FORBIDDEN_PATTERN}" "${STAGE}" 2>/dev/null \
                | grep -vE '(\.github/workflows/forbidden-strings\.yml)$' \
                | head -10); then
  if [ -n "${violations}" ]; then
    echo "✖ publish aborted: forbidden reference found in staged output." >&2
    echo "${violations}" >&2
    exit 1
  fi
fi
echo "   ok."

# --- Sync to public repo ---------------------------------------------------

if [ ! -d "${PUBLIC_REPO_DIR}" ]; then
  echo "✖ public repo dir not found: ${PUBLIC_REPO_DIR}" >&2
  echo "   create it (git init or git clone) and re-run, or set PUBLIC_REPO_DIR." >&2
  exit 1
fi

echo "→ Syncing to ${PUBLIC_REPO_DIR}"

# rsync with --delete makes the public working tree identical to the
# staged set. We protect the .git directory so the public repo's history
# survives.
rsync -a --delete \
  --exclude '.git' \
  "${STAGE}/" "${PUBLIC_REPO_DIR}/"

# --- Commit in the public repo --------------------------------------------

if $DO_COMMIT; then
  cd "${PUBLIC_REPO_DIR}"
  git add -A
  if git diff --cached --quiet; then
    echo "→ no changes to commit in public repo"
  else
    # release.yml triggers on `v*.*.*` tags, so tag with the leading `v`.
    TAG="v${VERSION}"
    git commit -m "Release ${VERSION}"
    git tag -a "${TAG}" -m "${TAG}"
    echo "✓ committed & tagged ${TAG} in public repo"
  fi
  if $DO_PUSH; then
    git push origin HEAD
    git push origin "v${VERSION}"
    echo "✓ pushed ${VERSION}"
  fi
fi

echo "✓ publish dry-run complete: ${STAGE}"
if ! $DO_COMMIT; then
  echo "  re-run with --commit to apply in ${PUBLIC_REPO_DIR}"
fi
