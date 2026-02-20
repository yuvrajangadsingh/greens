#!/bin/bash
#
# Private Work Contributions Mirror
#
# Mirrors commit timestamps from private work repos to a public repo,
# making your contribution graph reflect actual work without exposing code.
#
# https://github.com/yuvrajangadsingh/private-work-contributions-mirror

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.5.1"

# Source config file if it exists
# Config uses ${VAR:-value} so env vars always take precedence
CONFIG_FILE="${CONTRIB_MIRROR_CONFIG:-$HOME/.contrib-mirror/config}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# CLI flags
case "${1:-}" in
  --setup)   exec "$SCRIPT_DIR/setup.sh" ;;
  --help|-h) echo "Usage: contrib-mirror [--setup|--status|--reset|--help|--version]"
             echo "  --setup    Run interactive setup wizard"
             echo "  --status   Show current config and sync status"
             echo "  --reset    Remove config, caches, and scheduler"
             echo "  --version  Show version"
             echo "  --help     Show this help"
             exit 0 ;;
  --version) echo "contrib-mirror $VERSION"; exit 0 ;;
  --status)
    echo "contrib-mirror $VERSION"
    echo ""
    if [[ ! -f "$CONFIG_FILE" ]]; then
      echo "  Not configured. Run: contrib-mirror"
      exit 0
    fi
    source "$CONFIG_FILE"
    echo "  Config:       $CONFIG_FILE"
    echo "  Work dir:     ${WORK_DIR:-not set}"
    if [[ -d "${WORK_DIR:-}" ]]; then
      repo_count="$(find "$WORK_DIR" -maxdepth 2 -name .git -print 2>/dev/null | wc -l | tr -d ' ')"
      echo "  Repos found:  $repo_count"
    fi
    echo "  Remote prefix: ${REMOTE_PREFIX:-not set}"
    echo "  Emails:       ${EMAILS:-not set}"
    echo "  Mirror dir:   ${MIRROR_DIR:-not set}"
    if [[ -d "${MIRROR_DIR:-}" ]] && [[ -d "${MIRROR_DIR}/.git" ]]; then
      mirror_commits="$(git -C "$MIRROR_DIR" rev-list --count HEAD 2>/dev/null || echo "0")"
      echo "  Mirror commits: $mirror_commits"
    fi
    echo "  Mirror email: ${MIRROR_EMAIL:-$(git config user.email 2>/dev/null || echo "not set")}"
    echo "  GitHub user:  ${GITHUB_USERNAME:-not set}"
    echo "  Activity:     ${ACTIVITY_TYPES:-commits}"
    echo "  Since:        ${SINCE:-not set}"
    # Last sync
    log_dir="${LOG_DIR:-$SCRIPT_DIR/logs}"
    stamp_file="${SUCCESS_STAMP_FILE:-$log_dir/last-success-date}"
    if [[ -f "$stamp_file" ]]; then
      echo "  Last sync:    $(cat "$stamp_file")"
    else
      echo "  Last sync:    never"
    fi
    # Scheduler
    if launchctl list 2>/dev/null | grep -q "com.contrib-mirror"; then
      echo "  Scheduler:    launchd (active)"
    elif crontab -l 2>/dev/null | grep -q "sync.sh"; then
      echo "  Scheduler:    cron"
    else
      echo "  Scheduler:    none (manual)"
    fi
    exit 0 ;;
  --reset)
    echo "contrib-mirror — reset"
    echo ""
    confirm_reset() {
      printf "  %s [y/N]: " "$1" >&2
      read -r reply
      [[ "$reply" =~ ^[Yy] ]]
    }
    # 1. Scheduler
    if launchctl list 2>/dev/null | grep -q "com.contrib-mirror"; then
      if confirm_reset "Remove launchd scheduler?"; then
        launchctl bootout "gui/$(id -u)/com.contrib-mirror" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/com.contrib-mirror.plist"
        echo "  [ok] launchd agent removed"
      fi
    fi
    if crontab -l 2>/dev/null | grep -q "sync.sh"; then
      if confirm_reset "Remove cron entry?"; then
        crontab -l 2>/dev/null | grep -v "sync.sh" | crontab -
        echo "  [ok] cron entry removed"
      fi
    fi
    # 2. Cache
    config_dir="$HOME/.contrib-mirror"
    cache_dir="$SCRIPT_DIR/.cache"
    if [[ -d "$cache_dir" ]]; then
      if confirm_reset "Remove cache dir ($cache_dir)?"; then
        rm -rf "$cache_dir"
        echo "  [ok] cache removed"
      fi
    fi
    # 3. Mirror (before config removal — needs MIRROR_DIR from config)
    mirror="${MIRROR_DIR:-$config_dir/mirror}"
    if [[ -d "$mirror" ]]; then
      if confirm_reset "Remove mirror repo ($mirror)? This deletes all mirrored commits."; then
        rm -rf "$mirror"
        echo "  [ok] mirror removed"
      fi
    fi
    # 4. Config
    if [[ -f "$CONFIG_FILE" ]]; then
      if confirm_reset "Remove config ($CONFIG_FILE)?"; then
        rm -f "$CONFIG_FILE"
        echo "  [ok] config removed"
      fi
    fi
    # 5. Logs
    log_dir="${LOG_DIR:-$SCRIPT_DIR/logs}"
    config_log_dir="$config_dir/logs"
    for d in "$log_dir" "$config_log_dir"; do
      if [[ -d "$d" ]]; then
        if confirm_reset "Remove logs ($d)?"; then
          rm -rf "$d"
          echo "  [ok] logs removed"
        fi
      fi
    done
    # 6. Config dir if empty
    if [[ -d "$config_dir" ]] && [[ -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
      rmdir "$config_dir" 2>/dev/null || true
    fi
    echo ""
    echo "  Done. Run 'contrib-mirror' to set up again."
    exit 0 ;;
esac

# Auto-run setup on first use
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "No config found. Starting setup wizard..."
  echo ""
  "$SCRIPT_DIR/setup.sh"
  # If setup failed or user exited without creating config, bail
  if [[ ! -f "$CONFIG_FILE" ]]; then
    exit 1
  fi
  # Reload config written by setup
  source "$CONFIG_FILE"
  echo ""
  echo "Starting first sync..."
  echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Configuration (override via environment or edit below)
# ─────────────────────────────────────────────────────────────────────────────

# Directory containing your private work repos (will scan for git repos here)
WORK_DIR="${WORK_DIR:-$HOME/work}"

# Where to cache bare clones (avoids touching your working repos)
CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/.cache}"

# Your public mirror repo (create this on GitHub first)
MIRROR_DIR="${MIRROR_DIR:-$HOME/.contrib-mirror/mirror}"

# Only sync commits after this date
SINCE="${SINCE:-2024-01-01 00:00:00}"

# Your git emails (commits by these emails will be mirrored)
EMAILS="${EMAILS:-your-work-email@company.com,your-personal@gmail.com}"

# Remote URL prefix to match (e.g., "git@github.com:your-company/")
# Only repos with origin URLs starting with this prefix will be synced
REMOTE_PREFIX="${REMOTE_PREFIX:-git@github.com:your-company/}"

# GitHub organization name (extracted from REMOTE_PREFIX if not set)
GITHUB_ORG="${GITHUB_ORG:-}"

# GitHub username for API queries (for PRs, reviews, issues)
GITHUB_USERNAME="${GITHUB_USERNAME:-}"

# GitHub token for work account API access (optional)
# Option A: Set GITHUB_TOKEN with a PAT from your work account (https://github.com/settings/tokens, 'repo' scope)
# Option B: Login with both accounts via `gh auth login`, set GITHUB_USERNAME to your work account
# If neither is set, gh CLI uses whatever account is currently active
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Types of activity to track (comma-separated: commits,prs,reviews,issues)
# Set to "commits" only to disable GitHub API integration
ACTIVITY_TYPES="${ACTIVITY_TYPES:-commits,prs,reviews,issues}"

# Personal GitHub email for mirror commits (must match a verified email on your GitHub account)
# If not set, falls back to git's global user.email
MIRROR_EMAIL="${MIRROR_EMAIL:-}"

# Copy commit messages to mirror (0=timestamps only, 1=include messages)
# WARNING: Messages from private repos may contain sensitive info
COPY_MESSAGES="${COPY_MESSAGES:-0}"

# Log directory
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

# Success stamp file (prevents running multiple times per day)
SUCCESS_STAMP_FILE="${SUCCESS_STAMP_FILE:-$LOG_DIR/last-success-date}"

# ─────────────────────────────────────────────────────────────────────────────
# Auto-fill missing config (prompt inline, no full setup needed)
# ─────────────────────────────────────────────────────────────────────────────

if [[ -f "$CONFIG_FILE" ]] && [[ -z "$MIRROR_EMAIL" ]]; then
  echo "Your mirror commits need a personal GitHub email to show as green squares."
  echo "This must match a verified email on your GitHub account."
  printf "  Personal GitHub email: " >&2
  read -r MIRROR_EMAIL
  if [[ -n "$MIRROR_EMAIL" ]]; then
    echo "MIRROR_EMAIL=\"\${MIRROR_EMAIL:-$MIRROR_EMAIL}\"" >> "$CONFIG_FILE"
    echo "  Saved to config."
    echo ""
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$CACHE_DIR" "$LOG_DIR"

# Convert comma-separated emails to array
IFS=',' read -ra EMAIL_ARRAY <<< "$EMAILS"

# Lock to prevent concurrent runs
LOCK_DIR="/tmp/contrib-mirror-sync.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  existing_pid=""
  if [[ -f "$LOCK_DIR/pid" ]]; then
    existing_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  fi

  if [[ -n "$existing_pid" ]] && ps -p "$existing_pid" >/dev/null 2>&1; then
    echo "Another sync is already running (pid: $existing_pid). Exiting."
    exit 0
  fi

  echo "Stale lock detected. Removing and continuing."
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
fi

echo "$$" > "$LOCK_DIR/pid"

timestamp() {
  date "+%Y-%m-%d %H:%M:%S %z"
}

log() {
  echo "[$(timestamp)] $*"
}

# ─────────────────────────────────────────────────────────────────────────────
# GitHub Activity Functions (PRs, Reviews, Issues)
# ─────────────────────────────────────────────────────────────────────────────

# Convert ISO 8601 timestamp to git format
# Input:  2024-01-15T10:30:45Z or 2024-01-15T10:30:45+05:30
# Output: 2024-01-15 10:30:45 +0000 or 2024-01-15 10:30:45 +0530
iso_to_git_format() {
  local iso_ts="$1"
  if [[ "$iso_ts" == *"Z" ]]; then
    # UTC timestamp
    echo "$iso_ts" | sed 's/T/ /; s/Z/ +0000/'
  else
    # Timestamp with offset like +05:30
    echo "$iso_ts" | sed 's/T/ /; s/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/ \1\2/'
  fi
}

# Fetch GitHub activity timestamps (PRs, reviews, issues)
fetch_github_activity() {
  local since_date="$1"
  local org="$2"

  # Check if gh CLI is available
  if ! command -v gh &>/dev/null; then
    echo "[$(date "+%Y-%m-%d %H:%M:%S %z")] WARN: gh CLI not found, skipping GitHub activity fetch" >&2
    return
  fi

  # Auth: GITHUB_TOKEN takes priority, otherwise try account switching
  if [[ -n "$GITHUB_TOKEN" ]]; then
    export GITHUB_TOKEN
  elif [[ -n "$GITHUB_USERNAME" ]]; then
    local original_account
    original_account=$(gh auth status --active 2>&1 | grep 'Logged in' | sed 's/.*account //' | awk '{print $1}' || true)
    if [[ "$original_account" != "$GITHUB_USERNAME" ]]; then
      gh auth switch --user "$GITHUB_USERNAME" &>/dev/null || true
    fi
    trap 'if [[ -n "${original_account:-}" && "${original_account}" != "$GITHUB_USERNAME" ]]; then gh auth switch --user "$original_account" &>/dev/null || true; fi' RETURN
  fi

  # Check gh auth status
  if ! gh auth status &>/dev/null; then
    echo "[$(date "+%Y-%m-%d %H:%M:%S %z")] WARN: gh CLI not authenticated, skipping GitHub activity fetch" >&2
    return
  fi

  # PRs created
  if [[ "$ACTIVITY_TYPES" == *"prs"* ]]; then
    gh search prs --author="$GITHUB_USERNAME" --created=">=$since_date" \
      --owner="$org" --json createdAt --jq '.[].createdAt' 2>/dev/null | \
      while read -r ts; do
        [[ -n "$ts" ]] && iso_to_git_format "$ts"
      done
  fi

  # PR reviews
  if [[ "$ACTIVITY_TYPES" == *"reviews"* ]]; then
    gh search prs --reviewed-by="$GITHUB_USERNAME" --updated=">=$since_date" \
      --owner="$org" --json updatedAt --jq '.[].updatedAt' 2>/dev/null | \
      while read -r ts; do
        [[ -n "$ts" ]] && iso_to_git_format "$ts"
      done
  fi

  # Issues created
  if [[ "$ACTIVITY_TYPES" == *"issues"* ]]; then
    gh search issues --author="$GITHUB_USERNAME" --created=">=$since_date" \
      --owner="$org" --json createdAt --jq '.[].createdAt' 2>/dev/null | \
      while read -r ts; do
        [[ -n "$ts" ]] && iso_to_git_format "$ts"
      done
  fi
}

# Fetch GitHub activity with titles (timestamp<TAB>message format)
fetch_github_activity_with_messages() {
  local since_date="$1"
  local org="$2"

  if ! command -v gh &>/dev/null; then
    echo "[$(date "+%Y-%m-%d %H:%M:%S %z")] WARN: gh CLI not found, skipping GitHub activity fetch" >&2
    return
  fi

  if [[ -n "$GITHUB_TOKEN" ]]; then
    export GITHUB_TOKEN
  elif [[ -n "$GITHUB_USERNAME" ]]; then
    local original_account
    original_account=$(gh auth status --active 2>&1 | grep 'Logged in' | sed 's/.*account //' | awk '{print $1}' || true)
    if [[ "$original_account" != "$GITHUB_USERNAME" ]]; then
      gh auth switch --user "$GITHUB_USERNAME" &>/dev/null || true
    fi
    trap 'if [[ -n "${original_account:-}" && "${original_account}" != "$GITHUB_USERNAME" ]]; then gh auth switch --user "$original_account" &>/dev/null || true; fi' RETURN
  fi

  if ! gh auth status &>/dev/null; then
    echo "[$(date "+%Y-%m-%d %H:%M:%S %z")] WARN: gh CLI not authenticated, skipping GitHub activity fetch" >&2
    return
  fi

  if [[ "$ACTIVITY_TYPES" == *"prs"* ]]; then
    gh search prs --author="$GITHUB_USERNAME" --created=">=$since_date" \
      --owner="$org" --json createdAt,title --jq '.[] | .createdAt + "\t" + "PR: " + .title' 2>/dev/null | \
      while IFS=$'\t' read -r ts msg; do
        [[ -n "$ts" ]] && echo "$(iso_to_git_format "$ts")	$msg"
      done
  fi

  if [[ "$ACTIVITY_TYPES" == *"reviews"* ]]; then
    gh search prs --reviewed-by="$GITHUB_USERNAME" --updated=">=$since_date" \
      --owner="$org" --json updatedAt,title --jq '.[] | .updatedAt + "\t" + "Review: " + .title' 2>/dev/null | \
      while IFS=$'\t' read -r ts msg; do
        [[ -n "$ts" ]] && echo "$(iso_to_git_format "$ts")	$msg"
      done
  fi

  if [[ "$ACTIVITY_TYPES" == *"issues"* ]]; then
    gh search issues --author="$GITHUB_USERNAME" --created=">=$since_date" \
      --owner="$org" --json createdAt,title --jq '.[] | .createdAt + "\t" + "Issue: " + .title' 2>/dev/null | \
      while IFS=$'\t' read -r ts msg; do
        [[ -n "$ts" ]] && echo "$(iso_to_git_format "$ts")	$msg"
      done
  fi
}

tmp_pairs="$(mktemp)"
tmp_sorted="$(mktemp)"
cleanup() {
  rm -f "$tmp_pairs" "$tmp_sorted" /tmp/contrib_mirror_*.txt 2>/dev/null || true
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Skip if already synced today (set FORCE=1 to override)
# ─────────────────────────────────────────────────────────────────────────────

today="$(date '+%Y-%m-%d')"
if [[ "${FORCE:-0}" != "1" ]] && [[ -f "$SUCCESS_STAMP_FILE" ]]; then
  last_success_date="$(cat "$SUCCESS_STAMP_FILE" 2>/dev/null || true)"
  if [[ "$last_success_date" == "$today" ]]; then
    log "Already synced today ($today). Set FORCE=1 to run anyway."
    exit 0
  fi
fi

log "Starting contribution mirror sync"
log ""
log "Step 1/5: Finding work repos in $WORK_DIR"
log "  (Looking for git repos that match your org: $REMOTE_PREFIX)"

# ─────────────────────────────────────────────────────────────────────────────
# Discover repos
# ─────────────────────────────────────────────────────────────────────────────

find "$WORK_DIR" -maxdepth 2 -name .git -print 2>/dev/null | while read -r gitpath; do
  repodir="$(dirname "$gitpath")"

  # Skip cache directory
  case "$repodir" in
    "$CACHE_DIR"/*) continue ;;
  esac

  url="$(git -C "$repodir" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    continue
  fi

  # Only process repos matching the prefix
  case "$url" in
    "$REMOTE_PREFIX"*) ;;
    *) continue ;;
  esac

  remote_repo="$(basename "$url")"
  printf "%s %s\n" "$remote_repo" "$url" >> "$tmp_pairs"
done

if [[ ! -s "$tmp_pairs" ]]; then
  log "No matching repos found under $WORK_DIR (prefix: $REMOTE_PREFIX)"
  exit 1
fi

LC_ALL=C sort -u "$tmp_pairs" > "$tmp_sorted"

# ─────────────────────────────────────────────────────────────────────────────
# Fetch into bare caches (safe for local WIP)
# ─────────────────────────────────────────────────────────────────────────────

repo_total="$(wc -l < "$tmp_sorted" | tr -d " ")"
log ""
log "Step 2/5: Caching $repo_total repos (read-only copies — your code stays untouched)"

failures=0
fetched_ok=0
while read -r remote_repo url; do
  [[ -z "$remote_repo" ]] && continue
  bare="$CACHE_DIR/$remote_repo"

  if [[ ! -d "$bare" ]]; then
    log "Cloning $remote_repo"
    if ! err="$(git clone --bare --filter=blob:none --no-tags "$url" "$bare" 2>&1)"; then
      log "WARN: clone failed for $remote_repo: $(echo "$err" | tail -n 3 | tr '\n' ' ')"
      failures=$((failures + 1))
      rm -rf "$bare" >/dev/null 2>&1 || true
      continue
    fi
  fi

  git --git-dir="$bare" remote set-url origin "$url" >/dev/null 2>&1 || true

  if ! git --git-dir="$bare" config --get-all remote.origin.fetch >/dev/null 2>&1; then
    git --git-dir="$bare" config remote.origin.fetch "+refs/heads/*:refs/heads/*"
  fi

  log "Fetching $remote_repo"
  if ! err="$(git --git-dir="$bare" fetch --prune --no-tags --filter=blob:none origin "+refs/heads/*:refs/heads/*" 2>&1)"; then
    log "WARN: fetch failed for $remote_repo: $(echo "$err" | tail -n 3 | tr '\n' ' ')"
    failures=$((failures + 1))
    continue
  fi
  fetched_ok=$((fetched_ok + 1))
done < "$tmp_sorted"

if [[ "$failures" -gt 0 ]]; then
  log "WARN: $failures repos failed to fetch"
fi

if [[ "$fetched_ok" -eq 0 ]]; then
  log "ERROR: all fetches failed; not proceeding with stale data."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Collect unique timestamps
# ─────────────────────────────────────────────────────────────────────────────

tmp_all_data="/tmp/contrib_mirror_all.txt"
tmp_origin_ts="/tmp/contrib_mirror_origin_ts.txt"
tmp_mirror_ts="/tmp/contrib_mirror_mirror_ts.txt"
tmp_missing_ts="/tmp/contrib_mirror_missing_ts.txt"
tmp_missing_data="/tmp/contrib_mirror_missing_data.txt"

> "$tmp_all_data"

log ""
log "Step 3/5: Scanning commits across all branches (emails: $EMAILS)"
log "  (Checks every branch — feature, hotfix, etc. No double-counting after merge)"

# Collect git commits (with or without messages based on COPY_MESSAGES)
for bare in "$CACHE_DIR"/*.git; do
  [[ -d "$bare" ]] || continue

  origin_url="$(git --git-dir="$bare" remote get-url origin 2>/dev/null || true)"
  case "$origin_url" in
    "$REMOTE_PREFIX"*) ;;
    *) continue ;;
  esac

  for email in "${EMAIL_ARRAY[@]}"; do
    if [[ "$COPY_MESSAGES" == "1" ]]; then
      git --git-dir="$bare" log --all --since="$SINCE" --author="$email" --format="%ai	%s" 2>/dev/null || true
    else
      git --git-dir="$bare" log --all --since="$SINCE" --author="$email" --format="%ai" 2>/dev/null || true
    fi
  done
done >> "$tmp_all_data"

# Fetch GitHub activity (PRs, reviews, issues)
if [[ "$ACTIVITY_TYPES" != "commits" ]] && [[ -n "$GITHUB_USERNAME" ]]; then
  since_date="${SINCE%% *}"  # Extract date part only (YYYY-MM-DD)
  if [[ -z "$GITHUB_ORG" ]]; then
    GITHUB_ORG="$(echo "$REMOTE_PREFIX" | sed 's|.*[:/]\([^/]*\)/$|\1|')"
  fi
  log "Fetching GitHub activity (PRs, reviews, issues) since $since_date..."

  if [[ "$COPY_MESSAGES" == "1" ]]; then
    # Fetch with titles (timestamp<TAB>message format)
    fetch_github_activity_with_messages "$since_date" "$GITHUB_ORG" >> "$tmp_all_data"
  else
    # Fetch timestamps only
    fetch_github_activity "$since_date" "$GITHUB_ORG" >> "$tmp_all_data"
  fi

  total_count="$(wc -l < "$tmp_all_data" | tr -d " ")"
  log "Total entries (commits + GitHub activity): $total_count"
fi

# Deduplicate and extract timestamps for comparison
if [[ "$COPY_MESSAGES" == "1" ]]; then
  LC_ALL=C sort -t$'\t' -k1,1 -u "$tmp_all_data" > "$tmp_all_data.sorted"
  mv "$tmp_all_data.sorted" "$tmp_all_data"
  cut -f1 "$tmp_all_data" | LC_ALL=C sort -u > "$tmp_origin_ts"
else
  LC_ALL=C sort -u "$tmp_all_data" > "$tmp_origin_ts"
fi

{ git -C "$MIRROR_DIR" log --format="%ai" 2>/dev/null || true; } | LC_ALL=C sort -u > "$tmp_mirror_ts"
comm -23 "$tmp_origin_ts" "$tmp_mirror_ts" > "$tmp_missing_ts"

# Build missing data file (with messages if enabled)
if [[ "$COPY_MESSAGES" == "1" ]]; then
  > "$tmp_missing_data"
  while IFS= read -r ts; do
    [[ -z "$ts" ]] && continue
    msg="$(grep "^${ts}	" "$tmp_all_data" 2>/dev/null | head -1 | cut -f2-)"
    [[ -z "$msg" ]] && msg="sync"
    printf '%s\t%s\n' "$ts" "$msg" >> "$tmp_missing_data"
  done < "$tmp_missing_ts"
fi

origin_count="$(wc -l < "$tmp_origin_ts" | tr -d " ")"
mirror_count="$(wc -l < "$tmp_mirror_ts" | tr -d " ")"
missing_count="$(wc -l < "$tmp_missing_ts" | tr -d " ")"

log "Origin timestamps: $origin_count"
log "Mirror timestamps: $mirror_count"
log "Missing (to sync): $missing_count"

# ─────────────────────────────────────────────────────────────────────────────
# Add missing commits to mirror
# ─────────────────────────────────────────────────────────────────────────────

log ""
log "Step 4/5: Creating mirror commits (these show up as green squares on GitHub)"

# Set author identity for mirror commits — must match a verified email on the personal GitHub account
mirror_env=()
if [[ -n "$MIRROR_EMAIL" ]]; then
  mirror_env=(env GIT_AUTHOR_EMAIL="$MIRROR_EMAIL" GIT_COMMITTER_EMAIL="$MIRROR_EMAIL")
fi

if [[ "$missing_count" -gt 0 ]]; then
  log "Adding $missing_count new commits to mirror..."
  cd "$MIRROR_DIR"

  if [[ "$COPY_MESSAGES" == "1" ]]; then
    while IFS=$'\t' read -r ts msg; do
      [[ -z "$ts" ]] && continue
      [[ -z "$msg" ]] && msg="sync"
      GIT_AUTHOR_DATE="$ts" GIT_COMMITTER_DATE="$ts" "${mirror_env[@]}" git commit --allow-empty -m "$msg" --quiet
    done < "$tmp_missing_data"
  else
    while IFS= read -r ts; do
      [[ -z "$ts" ]] && continue
      GIT_AUTHOR_DATE="$ts" GIT_COMMITTER_DATE="$ts" "${mirror_env[@]}" git commit --allow-empty -m "sync" --quiet
    done < "$tmp_missing_ts"
  fi
  log "Mirror commits added."
else
  log "Mirror already up to date."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Update README with stats
# ─────────────────────────────────────────────────────────────────────────────

STATUS_FILE="$MIRROR_DIR/README.md"
final_mirror_count="$(git -C "$MIRROR_DIR" log --format="%ai" | LC_ALL=C sort -u | wc -l | tr -d " ")"

# Collect per-repo stats
tmp_repo_stats="/tmp/repo_stats.txt"
> "$tmp_repo_stats"
for bare in "$CACHE_DIR"/*.git; do
  [[ -d "$bare" ]] || continue
  repo_name="$(basename "$bare" .git)"

  origin_url="$(git --git-dir="$bare" remote get-url origin 2>/dev/null || true)"
  case "$origin_url" in
    "$REMOTE_PREFIX"*) ;;
    *) continue ;;
  esac

  repo_commits=0
  for email in "${EMAIL_ARRAY[@]}"; do
    count="$(git --git-dir="$bare" log --all --since="$SINCE" --author="$email" --format="%H" 2>/dev/null | wc -l | tr -d " ")"
    repo_commits=$((repo_commits + count))
  done

  if [[ "$repo_commits" -gt 0 ]]; then
    printf "%d|%s\n" "$repo_commits" "$repo_name" >> "$tmp_repo_stats"
  fi
done

sorted_repos="$(sort -t'|' -k1 -nr "$tmp_repo_stats")"
total_commits="$(echo "$sorted_repos" | awk -F'|' '{sum+=$1} END {print sum}')"
total_commits="${total_commits:-0}"

# Build repo breakdown
repo_breakdown=""
while IFS='|' read -r count name; do
  [[ -z "$count" ]] && continue
  if [[ "$total_commits" -gt 0 ]]; then
    percentage=$((count * 100 / total_commits))
  else
    percentage=0
  fi
  bar_length=$((percentage / 5))
  bar=""
  for ((i=0; i<bar_length; i++)); do bar+="█"; done
  for ((i=bar_length; i<20; i++)); do bar+="░"; done
  repo_breakdown+="| \`$name\` | $count | $bar $percentage% |
"
done <<< "$sorted_repos"

# Count active days
tmp_dates="/tmp/commit_dates.txt"
for bare in "$CACHE_DIR"/*.git; do
  [[ -d "$bare" ]] || continue
  origin_url="$(git --git-dir="$bare" remote get-url origin 2>/dev/null || true)"
  case "$origin_url" in
    "$REMOTE_PREFIX"*) ;;
    *) continue ;;
  esac
  for email in "${EMAIL_ARRAY[@]}"; do
    git --git-dir="$bare" log --all --since="$SINCE" --author="$email" --format="%ad" --date=short 2>/dev/null || true
  done
done | sort -u > "$tmp_dates"

total_active_days="$(wc -l < "$tmp_dates" | tr -d " ")"
repo_count="$(echo "$sorted_repos" | grep -c '|' || echo 0)"

mirror_mode="timestamps only"
[[ "$COPY_MESSAGES" == "1" ]] && mirror_mode="timestamps + messages"

cat > "$STATUS_FILE" << EOF
# Work Contributions Mirror

This repository mirrors commit ${mirror_mode} from private work repositories to maintain GitHub contribution visibility.

---

## Overview

| Metric | Value |
|:-------|------:|
| Total Commits | **$total_commits** |
| Active Days | **$total_active_days** |
| Repos Tracked | **$repo_count** |
| Since | $SINCE |

---

## Repository Breakdown

| Repository | Commits | Distribution |
|:-----------|--------:|:-------------|
$repo_breakdown
---

## Sync Info

| | |
|:--|:--|
| Last Sync | \`$(timestamp)\` |
| Mirror Commits | $final_mirror_count |
| Added This Run | $missing_count |
| Status | $(if [[ "$missing_count" -gt 0 ]]; then echo "✓ Synced"; else echo "✓ Up to date"; fi) |

---

<sub>Generated by [private-work-contributions-mirror](https://github.com/yuvrajangadsingh/private-work-contributions-mirror)</sub>
EOF

rm -f "$tmp_repo_stats" "$tmp_dates" 2>/dev/null || true

# Only commit README if we actually synced something
cd "$MIRROR_DIR"
git add README.md
if ! git diff --cached --quiet && [[ "$missing_count" -gt 0 ]]; then
  "${mirror_env[@]}" git commit -m "Update sync status" --quiet
  log "Status file updated."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Push
# ─────────────────────────────────────────────────────────────────────────────

log ""
log "Step 5/5: Pushing to GitHub (making your contribution graph green)"

push_output=""
if push_output="$(git push origin main 2>&1)"; then
  log "Mirror pushed."
elif push_output="$(git push origin master 2>&1)"; then
  log "Mirror pushed."
else
  log "ERROR: Push to mirror repo failed."
  log "$push_output"
  log ""
  log "Your commits were created locally but won't show on GitHub until push works."
  log "Fix: re-run 'contrib-mirror --setup' to reconfigure push access,"
  log "  or manually: git -C \"$MIRROR_DIR\" remote set-url origin https://<token>@github.com/<user>/<repo>.git"
fi

log "Mirror tip: $(git -C "$MIRROR_DIR" log -1 --format='%h %ai %s')"
echo "$today" > "$SUCCESS_STAMP_FILE"
log "Done."
