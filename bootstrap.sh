#!/usr/bin/env bash
set -euo pipefail
#
# Mimir workspace bootstrap
#
# Clones every Mimir repo as a sibling of this mimir-release checkout,
# producing the standard flat workspace layout. Safe to re-run: existing
# folders are skipped (with a fetch instead).
#
# Usage:
#   git clone https://github.com/ryanlane/mimir-release.git
#   cd mimir-release && ./bootstrap.sh
#   code mimir.code-workspace

# local-folder-name=remote-url
REPOS=(
  "mimir-server=https://github.com/ryanlane/Mimir-Platform.git"
  "mimir-display=https://github.com/ryanlane/mimir-display.git"
  "mimir-display-electron=https://github.com/ryanlane/mimir-display-electron.git"
  "mimir-display-magtag=https://github.com/ryanlane/magtag-circuitpython-display-mimir.git"
  "mimir-channel-photoframe=https://github.com/ryanlane/image-frame-channel-mimir.git"
  "mimir-channel-spotify=https://github.com/ryanlane/spotify-status.git"
  "mimir-docs=https://github.com/ryanlane/mimir-documentation.git"
)
# NOTE: if you rename the GitHub repos to match local names, update the URLs
# above (old URLs keep working via GitHub redirects, but explicit is better).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Workspace root: $PARENT_DIR"
for entry in "${REPOS[@]}"; do
  name="${entry%%=*}"
  url="${entry#*=}"
  dest="$PARENT_DIR/$name"
  if [ -d "$dest/.git" ]; then
    echo "✔ $name exists — fetching"
    git -C "$dest" fetch --all --prune
  else
    echo "⬇ cloning $name"
    git clone "$url" "$dest"
  fi
done

echo
echo "Done. Open the workspace with:"
echo "  code $SCRIPT_DIR/mimir.code-workspace"
