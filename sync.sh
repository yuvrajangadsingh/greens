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

# ─────────────────────────────────────────────────────────────────────────────
# Configuration (override via environment or edit below)
# ─────────────────────────────────────────────────────────────────────────────

# Directory containing your private work repos (will scan for git repos here)
WORK_DIR="${WORK_DIR:-$HOME/work}"

# Where to cache bare clones (avoids touching your working repos)
CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/.cache}"

# Your public mirror repo (create this on GitHub first)
MIRROR_DIR="${MIRROR_DIR:-$SCRIPT_DIR/mirror}"

# Only sync commits after this date
SINCE="${SINCE:-2024-01-01 00:00:00}"

# Your git emails (commits by these emails will be mirrored)
EMAILS="${EMAILS:-your-work-email@company.com,your-personal@gmail.com}"

# Remote URL prefix to match (e.g., "git@github.com:your-company/")
# Only repos with origin URLs starting with this prefix will be synced
REMOTE_PREFIX="${REMOTE_PREFIX:-git@github.com:your-company/}"

# Log directory
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

# Success stamp file (prevents running multiple times per day)
SUCCESS_STAMP_FILE="${SUCCESS_STAMP_FILE:-$LOG_DIR/last-success-date}"

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

tmp_pairs="$(mktemp)"
tmp_sorted="$(mktemp)"
cleanup() {
  rm -f "$tmp_pairs" "$tmp_sorted" 2>/dev/null || true
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
log "WORK_DIR=$WORK_DIR"
log "MIRROR_DIR=$MIRROR_DIR"
log "SINCE=$SINCE"

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

tmp_origin="/tmp/origin_timestamps.txt"
tmp_mirror="/tmp/mirror_timestamps.txt"
tmp_missing="/tmp/missing_timestamps.txt"

> "$tmp_origin"
for bare in "$CACHE_DIR"/*.git; do
  [[ -d "$bare" ]] || continue

  origin_url="$(git --git-dir="$bare" remote get-url origin 2>/dev/null || true)"
  case "$origin_url" in
    "$REMOTE_PREFIX"*) ;;
    *) continue ;;
  esac

  for email in "${EMAIL_ARRAY[@]}"; do
    git --git-dir="$bare" log --all --since="$SINCE" --author="$email" --format="%ai" 2>/dev/null || true
  done
done | LC_ALL=C sort -u > "$tmp_origin"

git -C "$MIRROR_DIR" log --format="%ai" 2>/dev/null | LC_ALL=C sort -u > "$tmp_mirror"
comm -23 "$tmp_origin" "$tmp_mirror" > "$tmp_missing"

origin_count="$(wc -l < "$tmp_origin" | tr -d " ")"
mirror_count="$(wc -l < "$tmp_mirror" | tr -d " ")"
missing_count="$(wc -l < "$tmp_missing" | tr -d " ")"

log "Origin timestamps: $origin_count"
log "Mirror timestamps: $mirror_count"
log "Missing (to sync): $missing_count"

# ─────────────────────────────────────────────────────────────────────────────
# Add missing commits to mirror
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$missing_count" -gt 0 ]]; then
  log "Adding $missing_count commits to mirror..."
  cd "$MIRROR_DIR"
  while IFS= read -r ts; do
    [[ -z "$ts" ]] && continue
    GIT_AUTHOR_DATE="$ts" GIT_COMMITTER_DATE="$ts" git commit --allow-empty -m "sync" --quiet
  done < "$tmp_missing"
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

cat > "$STATUS_FILE" << EOF
# Work Contributions Mirror

This repository mirrors commit timestamps from private work repositories to maintain GitHub contribution visibility.

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
  git commit -m "Update sync status" --quiet
  log "Status file updated."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Push
# ─────────────────────────────────────────────────────────────────────────────

log "Pushing mirror..."
git push origin main >/dev/null 2>&1 || git push origin master >/dev/null 2>&1
log "Mirror pushed."

log "Mirror tip: $(git -C "$MIRROR_DIR" log -1 --format='%h %ai %s')"
echo "$today" > "$SUCCESS_STAMP_FILE"
log "Done."
