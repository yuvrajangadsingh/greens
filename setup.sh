#!/bin/bash
#
# Interactive setup wizard for private-work-contributions-mirror
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.contrib-mirror"
CONFIG_FILE="$CONFIG_DIR/config"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

prompt() {
  local msg="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    printf "%s [%s]: " "$msg" "$default" >&2
  else
    printf "%s: " "$msg" >&2
  fi
  read -r reply
  echo "${reply:-$default}"
}

confirm() {
  local msg="$1"
  printf "%s [Y/n]: " "$msg" >&2
  read -r reply
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

info()  { echo "  $*" >&2; }
ok()    { echo "  [ok] $*" >&2; }
warn()  { echo "  [!] $*" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Auto-detection
# ─────────────────────────────────────────────────────────────────────────────

detect_work_dir() {
  for dir in "$HOME/work" "$HOME/projects" "$HOME/code" "$HOME/src" "$HOME/Sites/projects"; do
    if [[ -d "$dir" ]]; then
      # Find subdirs that contain git repos with a common org
      for sub in "$dir"/*/; do
        if find "$sub" -maxdepth 2 -name .git -print -quit 2>/dev/null | grep -q .; then
          echo "$sub"
          return
        fi
      done
    fi
  done
}

detect_emails() {
  local emails=""
  # Current git config email
  local current
  current="$(git config user.email 2>/dev/null || true)"
  [[ -n "$current" ]] && emails="$current"

  # Scan gitconfig includes for other emails
  local includes
  includes="$(git config --global --get-regexp 'includeIf\..*\.path' 2>/dev/null || true)"
  while read -r _ path; do
    [[ -z "$path" ]] && continue
    # Expand ~
    path="${path/#\~/$HOME}"
    if [[ -f "$path" ]]; then
      local inc_email
      inc_email="$(git config --file "$path" user.email 2>/dev/null || true)"
      if [[ -n "$inc_email" && "$inc_email" != "$current" ]]; then
        [[ -n "$emails" ]] && emails+=","
        emails+="$inc_email"
      fi
    fi
  done <<< "$includes"

  echo "$emails"
}

detect_remote_prefix() {
  local work_dir="$1"
  [[ -d "$work_dir" ]] || return

  # Collect origin URLs and find the most common org prefix
  local urls=""
  while read -r gitpath; do
    local url
    url="$(git -C "$(dirname "$gitpath")" remote get-url origin 2>/dev/null || true)"
    [[ -n "$url" ]] && urls+="$url"$'\n'
  done < <(find "$work_dir" -maxdepth 3 -name .git -print 2>/dev/null)

  # Find most common org prefix (git@github.com:Org/ or https://github.com/Org/)
  echo "$urls" | sed -n 's|\(.*github\.com[:/][^/]*/\).*|\1|p' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'
}

detect_github_username() {
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    gh auth status --active 2>&1 | grep 'Logged in' | sed 's/.*account //' | awk '{print $1}' || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Private Work Contributions Mirror - Setup"
echo "=========================================="
echo ""

# Load existing config if present
if [[ -f "$CONFIG_FILE" ]]; then
  info "Found existing config at $CONFIG_FILE"
  source "$CONFIG_FILE"
  echo ""
fi

# Detect values
info "Scanning for git repos..."
detected_work_dir="$(detect_work_dir)"
detected_emails="$(detect_emails)"
detected_prefix=""
if [[ -n "$detected_work_dir" ]]; then
  detected_prefix="$(detect_remote_prefix "$detected_work_dir")"
fi
detected_username="$(detect_github_username)"

# Use existing config values as fallback, then detected, then empty
default_work_dir="${WORK_DIR:-${detected_work_dir:-}}"
default_emails="${EMAILS:-${detected_emails:-}}"
default_prefix="${REMOTE_PREFIX:-${detected_prefix:-}}"
default_username="${GITHUB_USERNAME:-${detected_username:-}}"
default_since="${SINCE:-2024-01-01 00:00:00}"

# Strip trailing slashes for display
default_work_dir="${default_work_dir%/}"

echo ""
work_dir="$(prompt "Work repos directory" "$default_work_dir")"
work_dir="${work_dir%/}"

emails="$(prompt "Git author emails (comma-separated)" "$default_emails")"
remote_prefix="$(prompt "Remote URL prefix (e.g. git@github.com:YourOrg/)" "$default_prefix")"
github_username="$(prompt "GitHub username (for PR/review/issue tracking)" "$default_username")"
since="$(prompt "Mirror commits since" "$default_since")"

if [[ -n "$github_username" ]] && confirm "Track PRs, reviews, and issues too?"; then
  activity_types="commits,prs,reviews,issues"
else
  activity_types="commits"
fi

# Mirror repo setup
mirror_dir="${MIRROR_DIR:-$CONFIG_DIR/mirror}"
echo ""
info "Mirror repo will be at: $mirror_dir"
if [[ ! -d "$mirror_dir/.git" ]]; then
  mirror_url="$(prompt "Mirror repo URL (create an empty repo on GitHub first)" "")"
  if [[ -n "$mirror_url" ]]; then
    info "Cloning mirror repo..."
    git clone "$mirror_url" "$mirror_dir" 2>/dev/null || {
      info "Initializing new mirror repo..."
      mkdir -p "$mirror_dir"
      git -C "$mirror_dir" init --quiet
      git -C "$mirror_dir" remote add origin "$mirror_url"
      git -C "$mirror_dir" commit --allow-empty -m "init" --quiet
    }
    ok "Mirror repo ready"
  fi
else
  ok "Mirror repo already exists"
fi

# Write config
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" << 'HEADER'
# Private Work Contributions Mirror - Configuration
# Env vars override these values (e.g. WORK_DIR="/other" ./sync.sh)
HEADER
cat >> "$CONFIG_FILE" << EOF
# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')

WORK_DIR="\${WORK_DIR:-$work_dir}"
EMAILS="\${EMAILS:-$emails}"
REMOTE_PREFIX="\${REMOTE_PREFIX:-$remote_prefix}"
MIRROR_DIR="\${MIRROR_DIR:-$mirror_dir}"
GITHUB_USERNAME="\${GITHUB_USERNAME:-$github_username}"
ACTIVITY_TYPES="\${ACTIVITY_TYPES:-$activity_types}"
SINCE="\${SINCE:-$since}"
EOF

echo ""
ok "Config saved to $CONFIG_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler setup
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Set up automatic daily sync?"
echo "  1) launchd (macOS) - recommended"
echo "  2) cron"
echo "  3) Skip"
printf "  Choice [1]: " >&2
read -r sched_choice
sched_choice="${sched_choice:-1}"

sync_path="$SCRIPT_DIR/sync.sh"

case "$sched_choice" in
  1)
    label="com.contrib-mirror"
    plist="$HOME/Library/LaunchAgents/$label.plist"
    log_dir="$CONFIG_DIR/logs"
    mkdir -p "$log_dir"

    cat > "$plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>$sync_path</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
      <key>Hour</key>
      <integer>0</integer>
      <key>Minute</key>
      <integer>0</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$log_dir/sync.out.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/sync.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
  </dict>
</plist>
PLIST

    # Load the agent
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    ok "Daily sync scheduled via launchd (midnight)"
    ;;
  2)
    cron_line="0 0 * * * /bin/bash $sync_path >> $CONFIG_DIR/logs/sync.log 2>&1"
    mkdir -p "$CONFIG_DIR/logs"
    (crontab -l 2>/dev/null | grep -v "$sync_path"; echo "$cron_line") | crontab -
    ok "Daily sync scheduled via cron (midnight)"
    ;;
  *)
    info "Skipped. Run manually: contrib-mirror"
    ;;
esac

echo ""
ok "Setup complete! Run 'contrib-mirror' to sync now."
echo ""
