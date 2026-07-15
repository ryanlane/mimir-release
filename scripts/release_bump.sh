#!/usr/bin/env bash
set -euo pipefail

# Semi-automated release helper for Mimir.
#
# Default behavior is a dry run. Use --apply to make changes.
#
# What it does:
# - reads latest semantic tags from sibling repos
# - checks whether each repo actually has commits since its last tag; a
#   component with nothing new is skipped (bump downgraded to "none") so
#   running this doesn't publish a redundant, byte-identical release
# - computes next versions (patch/minor/major) for components that changed
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
ALLOW_DIRTY=0
SHOW_DIRTY=0
FORCE_UNCHANGED=0

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
  --allow-dirty             Allow apply mode with dirty working trees
  --show-dirty              Print dirty-file details for participating repos and exit
  --force-unchanged         Bump/tag a component even if it has no commits since its last tag
  --yes                     Skip interactive confirmation (only used with --apply)
  --no-fetch                Skip git fetch --tags in component repos
  -h, --help                Show this help

A component with no commits since its currently-tagged commit is skipped
(treated as bump=none) unless you pass an explicit --server-tag/--display-tag
or --force-unchanged. This avoids tagging + publishing a release that's
byte-identical to the last one just because the other component changed.

Examples:
  scripts/release_bump.sh
  scripts/release_bump.sh --server-bump minor --display-bump patch
  scripts/release_bump.sh --show-dirty
  scripts/release_bump.sh --apply
  scripts/release_bump.sh --apply --allow-dirty
  scripts/release_bump.sh --apply --force-unchanged
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

# True (exit 0) if $repo's checked-out HEAD has commits beyond what $tag
# points at — i.e. there's actually something new to release. The synthetic
# "v0.0.0" sentinel (no tags yet) always counts as changed. Resolution
# failures fail open (treated as "changed") so a git hiccup here can never
# silently block a real release.
repo_changed_since_tag() {
  local repo="$1"
  local tag="$2"

  [[ "$tag" == "v0.0.0" ]] && return 0

  local tag_commit head_commit
  tag_commit="$(git -C "$repo" rev-parse -q --verify "refs/tags/${tag}^{commit}")" || return 0
  head_commit="$(git -C "$repo" rev-parse HEAD)"

  [[ "$tag_commit" != "$head_commit" ]]
}

# Human-readable "N commits since <tag>" for the release-plan printout.
commits_since_tag() {
  local repo="$1"
  local tag="$2"

  if [[ "$tag" == "v0.0.0" ]]; then
    echo "no prior tag"
    return
  fi
  local count
  count="$(git -C "$repo" rev-list --count "${tag}..HEAD" 2>/dev/null || echo "?")"
  echo "${count} commit(s) since ${tag}"
}

require_clean_tree() {
  local repo="$1"
  local status
  status="$(git -C "$repo" status --short)"
  if [[ -n "$status" ]]; then
    echo "[ERR] Working tree not clean: $repo" >&2
    echo "$status" | sed 's/^/[ERR]   /' >&2
    die "Commit, stash, or discard changes in $(basename "$repo") before --apply"
  fi
}

warn_if_dirty_tree() {
  local repo="$1"
  if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
    info "WARNING: dirty working tree detected (dry-run allowed): $repo"
  fi
}

print_dirty_tree() {
  local repo="$1"
  local status
  status="$(git -C "$repo" status --short)"
  if [[ -n "$status" ]]; then
    info "DIRTY: $repo"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local path kind summary
      path="${line:3}"
      # --summary lines are indented (" mode change 100644 => 100755 ...")
      summary="$(git -C "$repo" diff --summary -- "$path" | head -n1 || true)"
      if [[ "$summary" == *"mode change"* ]]; then
        kind="mode-change"
      else
        kind="content-change"
      fi
      echo "  $line [$kind]"
    done <<< "$status"
  else
    info "CLEAN: $repo"
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

sync_display_pyproject() {
  local repo="$1"
  local version="$2"
  local file="$repo/pyproject.toml"

  [[ -f "$file" ]] || die "pyproject.toml not found in $repo"

  local current
  current="$(sed -nE 's/^version = "([^"]+)"$/\1/p' "$file" | head -n1)"
  [[ -n "$current" ]] || die "Could not find project version in $file"

  if [[ "$current" == "$version" ]]; then
    info "pyproject.toml already at $version; skipping bump commit"
    return 0
  fi

  sed -i -E "0,/^version = \"[^\"]+\"/s//version = \"$version\"/" "$file"

  local updated
  updated="$(sed -nE 's/^version = "([^"]+)"$/\1/p' "$file" | head -n1)"
  [[ "$updated" == "$version" ]] || die "Failed to update version in $file"

  git -C "$repo" add pyproject.toml
  git -C "$repo" commit -m "chore: bump version to $version"
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
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --show-dirty)
      SHOW_DIRTY=1
      shift
      ;;
    --force-unchanged)
      FORCE_UNCHANGED=1
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

if [[ "$SHOW_DIRTY" -eq 1 ]]; then
  print_dirty_tree "$SERVER_REPO"
  print_dirty_tree "$DISPLAY_REPO"
  print_dirty_tree "$RELEASE_REPO"
  exit 0
fi

# For safety, apply mode requires clean trees unless explicitly overridden.
if [[ "$APPLY" -eq 1 && "$ALLOW_DIRTY" -eq 0 ]]; then
  require_clean_tree "$SERVER_REPO"
  require_clean_tree "$DISPLAY_REPO"
  require_clean_tree "$RELEASE_REPO"
else
  if [[ "$APPLY" -eq 1 && "$ALLOW_DIRTY" -eq 1 ]]; then
    info "WARNING: apply mode running with --allow-dirty"
  fi
  warn_if_dirty_tree "$SERVER_REPO"
  warn_if_dirty_tree "$DISPLAY_REPO"
  warn_if_dirty_tree "$RELEASE_REPO"
fi

if [[ "$NO_FETCH" -eq 0 ]]; then
  info "Fetching tags from remotes"
  git -C "$SERVER_REPO" fetch --tags --prune --quiet
  git -C "$DISPLAY_REPO" fetch --tags --prune --quiet
fi

CURRENT_SERVER_TAG="$(latest_semver_tag "$SERVER_REPO")"
CURRENT_DISPLAY_TAG="$(latest_semver_tag "$DISPLAY_REPO")"

# Effective bump type, possibly downgraded to "none" below if the repo has
# nothing new since its current tag. Kept separate from $SERVER_BUMP/
# $DISPLAY_BUMP so messages can still say what was actually requested.
EFFECTIVE_SERVER_BUMP="$SERVER_BUMP"
EFFECTIVE_DISPLAY_BUMP="$DISPLAY_BUMP"

if [[ -z "$SERVER_TAG_OVERRIDE" ]] && [[ "$FORCE_UNCHANGED" -eq 0 ]] \
   && ! repo_changed_since_tag "$SERVER_REPO" "$CURRENT_SERVER_TAG"; then
  info "mimir-server: no commits since $CURRENT_SERVER_TAG — skipping bump (use --force-unchanged to override)"
  EFFECTIVE_SERVER_BUMP="none"
fi

if [[ -z "$DISPLAY_TAG_OVERRIDE" ]] && [[ "$FORCE_UNCHANGED" -eq 0 ]] \
   && ! repo_changed_since_tag "$DISPLAY_REPO" "$CURRENT_DISPLAY_TAG"; then
  info "mimir-display: no commits since $CURRENT_DISPLAY_TAG — skipping bump (use --force-unchanged to override)"
  EFFECTIVE_DISPLAY_BUMP="none"
fi

if [[ -n "$SERVER_TAG_OVERRIDE" ]]; then
  is_valid_semver_tag "$SERVER_TAG_OVERRIDE" || die "Invalid --server-tag value"
  NEXT_SERVER_TAG="$SERVER_TAG_OVERRIDE"
else
  NEXT_SERVER_TAG="$(bump_tag "$CURRENT_SERVER_TAG" "$EFFECTIVE_SERVER_BUMP")"
fi

if [[ -n "$DISPLAY_TAG_OVERRIDE" ]]; then
  is_valid_semver_tag "$DISPLAY_TAG_OVERRIDE" || die "Invalid --display-tag value"
  NEXT_DISPLAY_TAG="$DISPLAY_TAG_OVERRIDE"
else
  NEXT_DISPLAY_TAG="$(bump_tag "$CURRENT_DISPLAY_TAG" "$EFFECTIVE_DISPLAY_BUMP")"
fi

if [[ "$NEXT_SERVER_TAG" == "$CURRENT_SERVER_TAG" && "$NEXT_DISPLAY_TAG" == "$CURRENT_DISPLAY_TAG" ]]; then
  die "Nothing to release: neither repo has commits since its last tag (server=$CURRENT_SERVER_TAG, display=$CURRENT_DISPLAY_TAG). Use --force-unchanged to tag anyway."
fi

# Whether each component actually has a new tag to create — false when it
# was skipped above (unchanged) or explicitly requested as bump=none. Tag
# existence checks/creation/push are skipped entirely in that case: the
# "current" tag obviously already exists, so checking for it would only
# ever (incorrectly) look like a collision.
SERVER_TAG_CHANGED=0
[[ "$NEXT_SERVER_TAG" != "$CURRENT_SERVER_TAG" ]] && SERVER_TAG_CHANGED=1
DISPLAY_TAG_CHANGED=0
[[ "$NEXT_DISPLAY_TAG" != "$CURRENT_DISPLAY_TAG" ]] && DISPLAY_TAG_CHANGED=1

if [[ "$SERVER_TAG_CHANGED" -eq 1 ]]; then
  ensure_tag_not_exists_local "$SERVER_REPO" "$NEXT_SERVER_TAG"
  ensure_tag_not_exists_remote "$SERVER_REPO" "$NEXT_SERVER_TAG"
fi
if [[ "$DISPLAY_TAG_CHANGED" -eq 1 ]]; then
  ensure_tag_not_exists_local "$DISPLAY_REPO" "$NEXT_DISPLAY_TAG"
  ensure_tag_not_exists_remote "$DISPLAY_REPO" "$NEXT_DISPLAY_TAG"
fi

cat <<EOF

Release plan (channel: $CHANNEL)
- mimir-server:  $CURRENT_SERVER_TAG -> $NEXT_SERVER_TAG  ($(commits_since_tag "$SERVER_REPO" "$CURRENT_SERVER_TAG"))
- mimir-display: $CURRENT_DISPLAY_TAG -> $NEXT_DISPLAY_TAG  ($(commits_since_tag "$DISPLAY_REPO" "$CURRENT_DISPLAY_TAG"))
- pyproject:     mimir-display/pyproject.toml version -> ${NEXT_DISPLAY_TAG#v} (committed before tagging)
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

if [[ "$DISPLAY_TAG_CHANGED" -eq 1 ]]; then
  info "Syncing mimir-display pyproject.toml to ${NEXT_DISPLAY_TAG#v}"
  sync_display_pyproject "$DISPLAY_REPO" "${NEXT_DISPLAY_TAG#v}"
else
  info "mimir-display unchanged — skipping pyproject.toml sync"
fi

info "Creating annotated tags"
if [[ "$SERVER_TAG_CHANGED" -eq 1 ]]; then
  git -C "$SERVER_REPO" tag -a "$NEXT_SERVER_TAG" -m "mimir-server $NEXT_SERVER_TAG"
else
  info "mimir-server unchanged — no new tag"
fi
if [[ "$DISPLAY_TAG_CHANGED" -eq 1 ]]; then
  git -C "$DISPLAY_REPO" tag -a "$NEXT_DISPLAY_TAG" -m "mimir-display $NEXT_DISPLAY_TAG"
else
  info "mimir-display unchanged — no new tag"
fi

info "Updating versions.yml"
update_versions_file "$VERSIONS_FILE" "$CHANNEL" "$NEXT_SERVER_TAG" "$NEXT_DISPLAY_TAG"

# Build a commit message that only claims what actually changed.
bump_summary=()
[[ "$SERVER_TAG_CHANGED" -eq 1 ]] && bump_summary+=("server $NEXT_SERVER_TAG")
[[ "$DISPLAY_TAG_CHANGED" -eq 1 ]] && bump_summary+=("display-client $NEXT_DISPLAY_TAG")
bump_summary_joined=""
for item in "${bump_summary[@]}"; do
  if [[ -z "$bump_summary_joined" ]]; then
    bump_summary_joined="$item"
  else
    bump_summary_joined="$bump_summary_joined and $item"
  fi
done

info "Committing versions.yml in mimir-release"
git -C "$RELEASE_REPO" add versions.yml
git -C "$RELEASE_REPO" commit -m "release: bump $CHANNEL to $bump_summary_joined"

if [[ "$DISPLAY_TAG_CHANGED" -eq 1 ]]; then
  info "Pushing mimir-display branch (version bump commit)"
  git -C "$DISPLAY_REPO" push origin HEAD
fi

info "Pushing tags"
[[ "$SERVER_TAG_CHANGED" -eq 1 ]] && git -C "$SERVER_REPO" push origin "$NEXT_SERVER_TAG"
[[ "$DISPLAY_TAG_CHANGED" -eq 1 ]] && git -C "$DISPLAY_REPO" push origin "$NEXT_DISPLAY_TAG"

info "Pushing release repo commit"
git -C "$RELEASE_REPO" push

info "Done."
