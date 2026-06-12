#!/usr/bin/env bash
set -euo pipefail

# Semi-automated release helper for Mimir.
#
# Default behavior is a dry run. Use --apply to make changes.
#
# What it does:
# - reads latest semantic tags from sibling repos
# - computes next versions (patch/minor/major)
# - updates versions.yml (stable channel by default)
# - creates annotated tags
# - commits versions.yml
# - pushes tags + release commit
#
# Safety:
# - requires clean working trees
# - checks that target tags do not already exist remotely
# - prompts before apply unless --yes is set

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(dirname "$RELEASE_REPO")"

VERSIONS_FILE="$RELEASE_REPO/versions.yml"
CHANNEL="stable"
SERVER_BUMP="patch"
DISPLAY_BUMP="patch"
SERVER_TAG_OVERRIDE=""
DISPLAY_TAG_OVERRIDE=""
APPLY=0
ASSUME_YES=0
NO_FETCH=0

usage() {
  cat <<'EOF'
Usage:
  scripts/release_bump.sh [options]

Options:
  --channel <name>          Release channel in versions.yml (default: stable)
  --server-bump <type>      patch|minor|major|none (default: patch)
  --display-bump <type>     patch|minor|major|none (default: patch)
  --server-tag <vX.Y.Z>     Explicit server tag (overrides --server-bump)
  --display-tag <vX.Y.Z>    Explicit display tag (overrides --display-bump)
  --apply                   Apply changes (default is dry run)
  --yes                     Skip interactive confirmation (only used with --apply)
  --no-fetch                Skip git fetch --tags in component repos
  -h, --help                Show this help

Examples:
  scripts/release_bump.sh
  scripts/release_bump.sh --server-bump minor --display-bump patch
  scripts/release_bump.sh --apply
  scripts/release_bump.sh --server-tag v1.2.0 --display-tag v1.3.4 --apply
EOF
}

die() {
  echo "[ERR] $*" >&2
  exit 1
}

info() {
  echo "[INFO] $*"
}

is_valid_semver_tag() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

bump_tag() {
  local tag="$1"
  local bump="$2"

  is_valid_semver_tag "$tag" || die "Invalid tag format: $tag"

  local v major minor patch
  v="${tag#v}"
  IFS='.' read -r major minor patch <<< "$v"

  case "$bump" in
    patch)
      patch=$((patch + 1))
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    none)
      ;;
    *)
      die "Unknown bump type: $bump"
      ;;
  esac

  echo "v${major}.${minor}.${patch}"
}

latest_semver_tag() {
  local repo="$1"
  local tag

  tag="$(git -C "$repo" tag --list 'v*' --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)"
  if [[ -z "$tag" ]]; then
    echo "v0.0.0"
  else
    echo "$tag"
  fi
}

require_clean_tree() {
  local repo="$1"
  if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
    die "Working tree not clean: $repo"
  fi
}

ensure_tag_not_exists_remote() {
  local repo="$1"
  local tag="$2"

  if git -C "$repo" ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
    die "Tag already exists on origin for $(basename "$repo"): $tag"
  fi
}

ensure_tag_not_exists_local() {
  local repo="$1"
  local tag="$2"

  if git -C "$repo" rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    die "Tag already exists locally for $(basename "$repo"): $tag"
  fi
}

update_versions_file() {
  local file="$1"
  local channel="$2"
  local server_tag="$3"
  local display_tag="$4"

  local tmp
  tmp="$(mktemp)"

  awk -v ch="$channel" -v srv="$server_tag" -v dsp="$display_tag" '
    BEGIN { in_channel=0; saw_channel=0; saw_server=0; saw_display=0 }

    {
      if ($0 ~ "^" ch ":[[:space:]]*$") {
        in_channel=1
        saw_channel=1
        print
        next
      }

      if (in_channel && $0 ~ /^[^[:space:]]/) {
        in_channel=0
      }

      if (in_channel && $0 ~ /^[[:space:]]+server:[[:space:]]*/) {
        sub(/server:[[:space:]]*[^#[:space:]]+/, "server: " srv)
        saw_server=1
      }

      if (in_channel && $0 ~ /^[[:space:]]+display-client:[[:space:]]*/) {
        sub(/display-client:[[:space:]]*[^#[:space:]]+/, "display-client: " dsp)
        saw_display=1
      }

      print
    }

    END {
      if (!saw_channel || !saw_server || !saw_display) {
        exit 42
      }
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    die "Failed to update $file; ensure channel '$channel' has server and display-client keys"
  }

  mv "$tmp" "$file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --server-bump)
      SERVER_BUMP="${2:-}"
      shift 2
      ;;
    --display-bump)
      DISPLAY_BUMP="${2:-}"
      shift 2
      ;;
    --server-tag)
      SERVER_TAG_OVERRIDE="${2:-}"
      shift 2
      ;;
    --display-tag)
      DISPLAY_TAG_OVERRIDE="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --no-fetch)
      NO_FETCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -f "$VERSIONS_FILE" ]] || die "versions.yml not found at $VERSIONS_FILE"

case "$SERVER_BUMP" in patch|minor|major|none) ;; *) die "Invalid --server-bump" ;; esac
case "$DISPLAY_BUMP" in patch|minor|major|none) ;; *) die "Invalid --display-bump" ;; esac

SERVER_REPO="$WORKSPACE_ROOT/mimir-server"
DISPLAY_REPO="$WORKSPACE_ROOT/mimir-display"

[[ -d "$SERVER_REPO/.git" ]] || die "Missing repo: $SERVER_REPO"
[[ -d "$DISPLAY_REPO/.git" ]] || die "Missing repo: $DISPLAY_REPO"
[[ -d "$RELEASE_REPO/.git" ]] || die "Missing git repo: $RELEASE_REPO"

# Do not proceed if any participating repo has local changes.
require_clean_tree "$SERVER_REPO"
require_clean_tree "$DISPLAY_REPO"
require_clean_tree "$RELEASE_REPO"

if [[ "$NO_FETCH" -eq 0 ]]; then
  info "Fetching tags from remotes"
  git -C "$SERVER_REPO" fetch --tags --prune --quiet
  git -C "$DISPLAY_REPO" fetch --tags --prune --quiet
fi

CURRENT_SERVER_TAG="$(latest_semver_tag "$SERVER_REPO")"
CURRENT_DISPLAY_TAG="$(latest_semver_tag "$DISPLAY_REPO")"

if [[ -n "$SERVER_TAG_OVERRIDE" ]]; then
  is_valid_semver_tag "$SERVER_TAG_OVERRIDE" || die "Invalid --server-tag value"
  NEXT_SERVER_TAG="$SERVER_TAG_OVERRIDE"
else
  NEXT_SERVER_TAG="$(bump_tag "$CURRENT_SERVER_TAG" "$SERVER_BUMP")"
fi

if [[ -n "$DISPLAY_TAG_OVERRIDE" ]]; then
  is_valid_semver_tag "$DISPLAY_TAG_OVERRIDE" || die "Invalid --display-tag value"
  NEXT_DISPLAY_TAG="$DISPLAY_TAG_OVERRIDE"
else
  NEXT_DISPLAY_TAG="$(bump_tag "$CURRENT_DISPLAY_TAG" "$DISPLAY_BUMP")"
fi

if [[ "$NEXT_SERVER_TAG" == "$CURRENT_SERVER_TAG" && "$NEXT_DISPLAY_TAG" == "$CURRENT_DISPLAY_TAG" ]]; then
  die "No version change requested (both tags unchanged)"
fi

ensure_tag_not_exists_local "$SERVER_REPO" "$NEXT_SERVER_TAG"
ensure_tag_not_exists_local "$DISPLAY_REPO" "$NEXT_DISPLAY_TAG"
ensure_tag_not_exists_remote "$SERVER_REPO" "$NEXT_SERVER_TAG"
ensure_tag_not_exists_remote "$DISPLAY_REPO" "$NEXT_DISPLAY_TAG"

cat <<EOF

Release plan (channel: $CHANNEL)
- mimir-server:  $CURRENT_SERVER_TAG -> $NEXT_SERVER_TAG
- mimir-display: $CURRENT_DISPLAY_TAG -> $NEXT_DISPLAY_TAG
- versions file: $VERSIONS_FILE
- mode:          $([[ "$APPLY" -eq 1 ]] && echo "APPLY" || echo "DRY RUN")

EOF

if [[ "$APPLY" -eq 0 ]]; then
  info "Dry run complete. Re-run with --apply to execute."
  exit 0
fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
  read -r -p "Proceed with tag creation, versions.yml update, commit, and push? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *)
      info "Aborted."
      exit 1
      ;;
  esac
fi

info "Creating annotated tags"
git -C "$SERVER_REPO" tag -a "$NEXT_SERVER_TAG" -m "mimir-server $NEXT_SERVER_TAG"
git -C "$DISPLAY_REPO" tag -a "$NEXT_DISPLAY_TAG" -m "mimir-display $NEXT_DISPLAY_TAG"

info "Updating versions.yml"
update_versions_file "$VERSIONS_FILE" "$CHANNEL" "$NEXT_SERVER_TAG" "$NEXT_DISPLAY_TAG"

info "Committing versions.yml in mimir-release"
git -C "$RELEASE_REPO" add versions.yml
git -C "$RELEASE_REPO" commit -m "release: bump $CHANNEL to server $NEXT_SERVER_TAG and display-client $NEXT_DISPLAY_TAG"

info "Pushing tags"
git -C "$SERVER_REPO" push origin "$NEXT_SERVER_TAG"
git -C "$DISPLAY_REPO" push origin "$NEXT_DISPLAY_TAG"

info "Pushing release repo commit"
git -C "$RELEASE_REPO" push

info "Done."
