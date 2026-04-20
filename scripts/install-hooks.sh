#!/usr/bin/env bash
# Install git hooks for this repo. Run once after clone.
#
#   $ ./scripts/install-hooks.sh
#
# Uses symlinks so updates to the hook scripts take effect immediately
# without reinstalling.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "${repo_root}"

hooks_src="scripts/hooks"
hooks_dst=".git/hooks"

if [ ! -d "${hooks_dst}" ]; then
  echo "✖ .git/hooks not found. Are you inside a git checkout?"
  exit 1
fi

for src in "${hooks_src}"/*; do
  name=$(basename "${src}")
  dst="${hooks_dst}/${name}"
  chmod +x "${src}"
  ln -sf "../../${src}" "${dst}"
  echo "✓ installed ${name}"
done
