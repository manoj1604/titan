#!/bin/bash
# Fills in the repository placeholders before the first release.
# Usage: scripts/set-repo.sh <github-owner>          e.g. scripts/set-repo.sh acme
# Replaces OWNER in links, the Homebrew formula, the CLI help and the Go module path.
# (The release date and the formula's sha256 are filled in at release time.)
set -euo pipefail
cd "$(dirname "$0")/.."
owner="${1:?usage: scripts/set-repo.sh <github-owner>}"
[[ "$owner" =~ ^[A-Za-z0-9-]+$ ]] || { echo "error: '$owner' isn't a valid GitHub owner" >&2; exit 1; }
files=$(grep -rlI "OWNER" --exclude-dir=.build --exclude-dir=dist --exclude-dir=.git --exclude="set-repo.sh" . || true)
[ -n "$files" ] || { echo "no OWNER placeholders left"; exit 0; }
for f in $files; do LC_ALL=C sed -i '' "s/OWNER/$owner/g" "$f"; echo "  updated $f"; done
echo "Now run: scripts/gen-cli-docs.sh   (the CLI help contains the repo link)"
