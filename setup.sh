#!/bin/bash
#
# Interactive setup wizard for greens
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
fail()  { echo "  [✗] $*" >&2; }

# Mask credentials in URLs (https://TOKEN@github.com/... -> https://****@github.com/...)
mask_url() {
  echo "$1" | sed 's|https://[^@]*@|https://****@|'
}

# Detect personal SSH host and GitHub username.
# Parses ~/.ssh/config for GitHub hosts, runs ssh -T on each,
# returns the one that ISN'T the work account.
# Sets: PERSONAL_SSH_HOST, PERSONAL_GH_USER
detect_personal_ssh() {
  local work_user="${1:-}" work_host="${2:-}"
  PERSONAL_SSH_HOST=""
  PERSONAL_GH_USER=""

  [[ ! -f "$HOME/.ssh/config" ]] && return 1

  # Extract all GitHub host aliases from SSH config
  local hosts=()
  while IFS= read -r line; do
    # Match "Host github*" or "Host *github*" lines, extract the alias
    local h
    h="$(echo "$line" | sed -n 's/^[Hh]ost[[:space:]][[:space:]]*//p' | tr -d ' ')"
    [[ -n "$h" && "$h" != "*" ]] && hosts+=("$h")
  done < <(grep -i "^[[:space:]]*host[[:space:]].*github" "$HOME/.ssh/config" 2>/dev/null | grep -iv "hostname")

  [[ ${#hosts[@]} -lt 2 ]] && return 1

  for h in "${hosts[@]}"; do
    # Skip the known work host
    [[ "$h" == "$work_host" ]] && continue

    # Test SSH and extract username
    local ssh_output
    ssh_output="$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 "git@$h" 2>&1 || true)"
    local gh_user
    gh_user="$(echo "$ssh_output" | sed -n 's/.*Hi \([^!]*\)!.*/\1/p' | head -1)"

    if [[ -n "$gh_user" && "$gh_user" != "$work_user" ]]; then
      PERSONAL_SSH_HOST="$h"
      PERSONAL_GH_USER="$gh_user"
      return 0
    fi
  done
  return 1
}

# Prompt for HTTPS token and embed in mirror remote URL.
# Usage: fix_https_auth <mirror_dir> <current_url>
fix_https_auth() {
  local mdir="$1" url="$2" mirror_token=""
  info "HTTPS repos need authentication to push."
  echo ""
  info "Create a PAT on your PERSONAL GitHub account (not work):"
  info "  https://github.com/settings/tokens/new"
  info "  Scope: [x] repo"
  echo ""
  if confirm "Do you have a personal GitHub token for push access?"; then
    printf "  Paste token (hidden): " >&2
    read -rs mirror_token
    echo "" >&2
  else
    echo ""
    info "How to create one:"
    info "  1. Go to: https://github.com/settings/tokens/new"
    info "     (Make sure you're logged into your PERSONAL GitHub, not work)"
    info "  2. Note: greens-push"
    info "  3. Expiration: 90 days"
    info "  4. Select scopes: [x] repo"
    info "  5. Click 'Generate token' and copy it"
    echo ""
    if confirm "Ready to paste the token?"; then
      printf "  Paste token (hidden): " >&2
      read -rs mirror_token
      echo "" >&2
    else
      mirror_token=""
    fi
  fi
  if [[ -n "${mirror_token:-}" ]]; then
    local authed_url
    authed_url="$(echo "$url" | sed "s|https://[^@]*@|https://|; s|https://|https://${mirror_token}@|")"
    git -C "$mdir" remote set-url origin "$authed_url"
    if git -C "$mdir" push origin HEAD 2>/dev/null; then
      ok "Push access works now"
      return 0
    else
      warn "Still can't push. Check that the token has repo scope and the repo exists."
      return 1
    fi
  else
    warn "Skipping — commits won't push to GitHub until auth is configured."
    info "Fix later: greens --setup"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites check
# ─────────────────────────────────────────────────────────────────────────────

check_prerequisites() {
  echo ""
  echo "Checking prerequisites..."
  echo ""
  local has_errors=0

  # Git
  if command -v git &>/dev/null; then
    ok "git $(git --version | awk '{print $3}')"
  else
    fail "git not found"
    info "  Install: https://git-scm.com/downloads"
    info "  macOS:   xcode-select --install"
    info "  Ubuntu:  sudo apt install git"
    has_errors=1
  fi

  # Bash version
  local bash_ver="${BASH_VERSION%%(*}"
  if [[ "${bash_ver%%.*}" -ge 4 ]]; then
    ok "bash $bash_ver"
  else
    warn "bash $bash_ver (version 4+ recommended)"
    info "  macOS ships bash 3.x. Install newer: brew install bash"
  fi

  # SSH key
  local has_ssh_key=0
  if [[ -f "$HOME/.ssh/id_ed25519.pub" ]] || [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
    ok "SSH key found"
    has_ssh_key=1
  else
    warn "No SSH key found (needed if your repos use SSH remotes)"
    info "  Generate one: ssh-keygen -t ed25519 -C \"your@email.com\""
    info "  Then add to GitHub: https://github.com/settings/keys"
  fi

  # SSH access to GitHub
  if [[ "$has_ssh_key" == "1" ]]; then
    if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
      ok "SSH access to GitHub works"
    else
      warn "SSH to github.com didn't confirm auth (may still work with HTTPS repos)"
    fi
  fi

  # gh CLI (optional)
  if command -v gh &>/dev/null; then
    ok "gh CLI $(gh --version | head -1 | awk '{print $3}')"
    if gh auth status &>/dev/null 2>&1; then
      ok "gh CLI authenticated"
    else
      warn "gh CLI installed but not logged in"
      info "  Run: gh auth login"
    fi
  else
    warn "gh CLI not found (optional — needed for PR/review/issue tracking)"
    info "  Install: brew install gh  OR  https://cli.github.com/"
  fi

  echo ""

  if [[ "$has_errors" == "1" ]]; then
    echo "  Fix the issues above and re-run setup."
    echo ""
    exit 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Auth detection & guidance
# ─────────────────────────────────────────────────────────────────────────────

detect_auth_method() {
  local work_dir="$1"
  [[ -d "$work_dir" ]] || { echo "unknown"; return 0; }

  local ssh_count=0 https_count=0
  while IFS= read -r gitpath; do
    local url
    url="$(git -C "$(dirname "$gitpath")" remote get-url origin 2>/dev/null || true)"
    if [[ "$url" == git@* ]] || [[ "$url" == ssh://* ]]; then
      ((ssh_count++)) || true
    elif [[ "$url" == https://* ]]; then
      ((https_count++)) || true
    fi
  done < <(find "$work_dir" -maxdepth 3 -name .git -print 2>/dev/null)

  if [[ "$ssh_count" -gt "$https_count" ]]; then
    echo "ssh"
  elif [[ "$https_count" -gt 0 ]]; then
    echo "https"
  else
    echo "unknown"
  fi
}

show_token_guide() {
  echo ""
  echo "  How to create a GitHub Personal Access Token"
  echo "  ─────────────────────────────────────────────"
  echo ""
  echo "  Option 1: Fine-grained token (recommended)"
  echo "  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "  1. Go to: https://github.com/settings/personal-access-tokens/new"
  echo "  2. Token name: greens"
  echo "  3. Expiration: 90 days (or custom)"
  echo "  4. Resource owner: Select your work org"
  echo "  5. Repository access: All repositories"
  echo "  6. Permissions → Repository permissions:"
  echo "     • Commit statuses  → Read-only"
  echo "     • Contents         → Read-only"
  echo "     • Issues           → Read-only"
  echo "     • Metadata         → Read-only (auto-selected)"
  echo "     • Pull requests    → Read-only"
  echo "  7. Click 'Generate token' and copy it"
  echo ""
  echo "  Option 2: Classic token (simpler, but gives write access too)"
  echo "  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "  1. Go to: https://github.com/settings/tokens/new"
  echo "  2. Note: greens"
  echo "  3. Expiration: 90 days (or custom)"
  echo "  4. Select scopes:"
  echo "     • [x] repo (full control — no read-only option for private repos)"
  echo "  5. Click 'Generate token' and copy it"
  echo ""
  echo "  NOTE: Classic tokens don't support read-only private repo access."
  echo "  The sub-scopes (repo:status, public_repo) only work for public repos."
  echo "  Use fine-grained tokens if you want read-only access to private repos."
  echo ""
}

prompt_for_token() {
  if confirm "Do you have a GitHub PAT ready?"; then
    local token
    printf "  Paste your token (hidden): " >&2
    read -rs token
    echo "" >&2
    if [[ -n "$token" ]]; then
      # Quick validation — check token format
      if [[ "$token" == ghp_* ]] || [[ "$token" == github_pat_* ]]; then
        DETECTED_TOKEN="$token"
        ok "Token saved (will be written to config)"
      else
        warn "Token doesn't look like a GitHub PAT (expected ghp_... or github_pat_...)"
        if confirm "  Save it anyway?"; then
          DETECTED_TOKEN="$token"
          ok "Token saved"
        fi
      fi
    fi
  else
    echo ""
    info "No worries — here's how to create one:"
    show_token_guide
    if confirm "Want to enter a token now?"; then
      local token
      printf "  Paste your token (hidden): " >&2
      read -rs token
      echo "" >&2
      if [[ -n "$token" ]]; then
        DETECTED_TOKEN="$token"
        ok "Token saved (will be written to config)"
      fi
    else
      warn "Skipping — PR/review/issue tracking won't work without a token."
      info "  You can add it later: greens --setup"
    fi
  fi
}

guide_auth_setup() {
  local auth_method="$1" github_username="$2"

  echo ""
  echo "Auth Setup"
  echo "----------"

  if [[ "$auth_method" == "ssh" ]]; then
    info "Your repos use SSH remotes."
    echo ""

    # Check if they have multi-account SSH config
    local has_multi_ssh=0
    if [[ -f "$HOME/.ssh/config" ]]; then
      if grep -qi "github" "$HOME/.ssh/config" 2>/dev/null; then
        local host_count
        host_count="$(grep -ci "host.*github" "$HOME/.ssh/config" 2>/dev/null || echo "0")"
        if [[ "$host_count" -gt 1 ]]; then
          has_multi_ssh=1
          ok "Multi-account SSH config detected ($host_count GitHub hosts)"
        fi
      fi
    fi

    if [[ "$has_multi_ssh" == "0" ]]; then
      info "You have a single SSH key for GitHub — that works fine if your"
      info "one GitHub account has access to both personal and work repos."
      echo ""
      if confirm "Do you use separate GitHub accounts for work and personal?"; then
        echo ""
        info "You'll need either:"
        echo ""
        info "  Option A: SSH config with separate hosts (recommended)"
        info "  ─────────────────────────────────────────────────────"
        info "  Add to ~/.ssh/config:"
        echo ""
        info "    # Personal"
        info "    Host github.com"
        info "      HostName github.com"
        info "      IdentityFile ~/.ssh/id_personal"
        echo ""
        info "    # Work"
        info "    Host github-work"
        info "      HostName github.com"
        info "      IdentityFile ~/.ssh/id_work"
        echo ""
        info "  Then clone work repos with: git clone git@github-work:org/repo.git"
        echo ""
        info "  Option B: Personal Access Token for API calls"
        info "  ──────────────────────────────────────────────"
        show_token_guide
        if confirm "Want to set up a token now?"; then
          prompt_for_token
        elif ! confirm "Continue setup without multi-account auth?"; then
          info "Set up SSH or PAT first, then re-run: greens --setup"
          exit 0
        fi
      fi
    fi

  elif [[ "$auth_method" == "https" ]]; then
    info "Your repos use HTTPS remotes."
    echo ""
    info "For cloning work repos, make sure you have a credential helper:"
    info "  Check: git config credential.helper"
    echo ""
    info "For GitHub API (PR/review tracking), you'll need a Personal Access Token."
    echo ""
    prompt_for_token

  else
    info "Auth method not determined. You can set up auth later."
    info "  SSH:   ssh-keygen + add key to GitHub"
    info "  HTTPS: gh auth login  OR  set up a PAT"
  fi

  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Auto-detection
# ─────────────────────────────────────────────────────────────────────────────

detect_work_dir() {
  local best="" best_count=0
  for dir in "$HOME/work" "$HOME/projects" "$HOME/code" "$HOME/src" "$HOME/Sites/projects"; do
    [[ -d "$dir" ]] || continue
    for sub in "$dir"/*/; do
      [[ -d "$sub" ]] || continue
      local count
      count="$(find "$sub" -maxdepth 2 -name .git -print 2>/dev/null | wc -l | tr -d ' ')"
      if [[ "$count" -gt "$best_count" ]]; then
        best_count="$count"
        best="$sub"
      fi
    done
  done
  echo "${best:-}"
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
  [[ -d "$work_dir" ]] || return 0

  # Collect origin URLs, extract org prefix, find most common
  find "$work_dir" -maxdepth 3 -name .git -print 2>/dev/null | while read -r gitpath; do
    git -C "$(dirname "$gitpath")" remote get-url origin 2>/dev/null || true
  done | sed 's|/[^/]*\.git$||; s|/[^/]*$||; s|$|/|' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'
}

detect_github_username() {
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    gh auth status --active 2>&1 | grep 'Logged in' | sed 's/.*account //' | awk '{print $1}' || true
  fi
}

detect_org_name() {
  local work_dir="$1"
  [[ -d "$work_dir" ]] || return 0
  find "$work_dir" -maxdepth 3 -name .git -print 2>/dev/null | while read -r gitpath; do
    git -C "$(dirname "$gitpath")" remote get-url origin 2>/dev/null || true
  done | sed -n 's|.*[:/]\([^/]*\)/[^/]*$|\1|p' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'
}

detect_ssh_host() {
  local work_dir="$1"
  [[ -d "$work_dir" ]] || { echo "github.com"; return 0; }
  local host
  host="$(find "$work_dir" -maxdepth 3 -name .git -print 2>/dev/null | while read -r gitpath; do
    git -C "$(dirname "$gitpath")" remote get-url origin 2>/dev/null || true
  done | sed -n 's|^git@\([^:]*\):.*|\1|p' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
  echo "${host:-github.com}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Private Work Contributions Mirror - Setup"
echo "=========================================="
echo ""
echo "  This tool mirrors your private work commit activity to a public"
echo "  GitHub repo, so your contribution graph reflects all your work."

# Check prerequisites first
check_prerequisites

# Load existing config if present
if [[ -f "$CONFIG_FILE" ]]; then
  info "Found existing config at $CONFIG_FILE"
  source "$CONFIG_FILE"
  echo ""
fi

# ── Step 1: Work directory ──────────────────────────────────────────────────

info "Scanning for git repos..."
detected_work_dir="$(detect_work_dir)"
detected_emails="$(detect_emails)"
detected_username="$(detect_github_username)"

# Use existing config values as fallback, then detected, then empty
default_work_dir="${WORK_DIR:-${detected_work_dir:-}}"
default_emails="${EMAILS:-${detected_emails:-}}"
default_username="${GITHUB_USERNAME:-${detected_username:-}}"
default_since="${SINCE:-2024-01-01 00:00:00}"

# Strip trailing slashes for display
default_work_dir="${default_work_dir%/}"

echo ""
if [[ -z "$default_work_dir" ]]; then
  info "Where are your work git repositories?"
  info "This should be the parent folder containing your work repos."
  info ""
  info "  Example structure:"
  info "    ~/work/"
  info "      ├── backend-api/      (.git)"
  info "      ├── auth-service/     (.git)"
  info "      └── data-pipeline/    (.git)"
  echo ""
fi
work_dir="$(prompt "Work repos directory" "$default_work_dir")"

# Resolve to absolute path
work_dir="${work_dir/#\~/$HOME}"
if [[ -n "$work_dir" && "$work_dir" != /* ]]; then
  work_dir="$(cd "$work_dir" 2>/dev/null && pwd || echo "$(pwd)/$work_dir")"
fi
work_dir="${work_dir%/}"

if [[ -n "$work_dir" ]] && [[ ! -d "$work_dir" ]]; then
  warn "Directory '$work_dir' doesn't exist yet."
  if confirm "Create it now?"; then
    mkdir -p "$work_dir"
    ok "Created $work_dir"
    info "Clone your work repos into this directory, then run: greens"
  fi
fi

# Show found repos
repo_count=0
if [[ -d "$work_dir" ]]; then
  while IFS= read -r _gitpath; do
    ((repo_count++)) || true
  done < <(find "$work_dir" -maxdepth 2 -name .git -print 2>/dev/null)

  if [[ "$repo_count" -gt 0 ]]; then
    echo ""
    ok "Found $repo_count git repo(s) in $work_dir/"
    _shown=0
    while IFS= read -r _g; do
      info "  ├── $(basename "$(dirname "$_g")")"
      ((_shown++)) || true
      [[ "$_shown" -ge 5 ]] && break
    done < <(find "$work_dir" -maxdepth 2 -name .git -print 2>/dev/null)
    if [[ "$repo_count" -gt 5 ]]; then
      info "  └── ... and $((repo_count - 5)) more"
    fi
  else
    echo ""
    warn "No git repos found in $work_dir/ yet"
    info "Clone your work repos there, then run: greens"
  fi
fi

# ── Step 2: Auth & org detection ────────────────────────────────────────────

auth_method="unknown"
detected_org=""
detected_ssh_host="github.com"
if [[ -d "$work_dir" ]] && [[ "$repo_count" -gt 0 ]]; then
  auth_method="$(detect_auth_method "$work_dir")"
  detected_org="$(detect_org_name "$work_dir")"
  detected_ssh_host="$(detect_ssh_host "$work_dir")"
fi

# If we couldn't detect auth method, ask
if [[ "$auth_method" == "unknown" ]]; then
  echo ""
  echo "  How do you access work repos on GitHub?"
  echo "    1) SSH   (git@github.com:org/repo.git)"
  echo "    2) HTTPS (https://github.com/org/repo.git)"
  echo "    3) Not sure yet — skip"
  printf "  Choice [1]: " >&2
  read -r auth_choice
  auth_choice="${auth_choice:-1}"
  case "$auth_choice" in
    2) auth_method="https" ;;
    3) auth_method="unknown" ;;
    *) auth_method="ssh" ;;
  esac
fi

if [[ "$auth_method" != "unknown" ]]; then
  echo ""
  info "Using $(echo "$auth_method" | tr '[:lower:]' '[:upper:]') for GitHub access"
fi

# Auth guidance
DETECTED_TOKEN=""
if [[ "$auth_method" != "unknown" ]]; then
  guide_auth_setup "$auth_method" "${default_username:-}"
fi

# ── Step 3: User inputs ────────────────────────────────────────────────────

emails="$(prompt "Git author email(s) for work commits (comma-separated)" "$default_emails")"

# Ask for org name, construct remote prefix automatically
echo ""
org_name="$(prompt "Work GitHub org/owner name" "${detected_org:-}")"
if [[ -n "$org_name" ]]; then
  if [[ "$auth_method" == "ssh" ]]; then
    remote_prefix="git@${detected_ssh_host}:${org_name}/"
  else
    remote_prefix="https://github.com/${org_name}/"
  fi
  ok "Remote prefix: $remote_prefix"
else
  # Fallback for users who don't use GitHub or have unusual setups
  remote_prefix="$(prompt "Remote URL prefix (e.g. git@github.com:YourOrg/)" "")"
fi

github_username="$(prompt "Work GitHub username (for PR/review/issue tracking)" "$default_username")"

# Personal email for mirror commits — GitHub uses this to attribute green squares
# Preserve existing config on rerun, but do NOT auto-detect from git (it's likely the work email)
default_mirror_email="${MIRROR_EMAIL:-}"
echo ""
info "Your PERSONAL GitHub email (not work). This is how GitHub"
info "knows to light up green squares on YOUR profile."
mirror_email="$(prompt "Personal GitHub email" "$default_mirror_email")"
if [[ -z "$mirror_email" ]]; then
  warn "No email provided. Green squares won't appear until you set this."
  info "Fix later: greens --setup"
fi

since="$(prompt "Mirror commits since" "$default_since")"

if [[ -n "$github_username" ]] && confirm "Track PRs, reviews, and issues too?"; then
  activity_types="commits,prs,reviews,issues"
else
  activity_types="commits"
fi

# Warn if mirror email matches work email
if [[ -n "$mirror_email" && -n "$emails" ]]; then
  for e in ${emails//,/ }; do
    if [[ "$e" == "$mirror_email" ]]; then
      echo ""
      warn "Your mirror email ($mirror_email) matches a work email."
      warn "This should be your PERSONAL GitHub email for green squares to show"
      warn "on your personal profile. If this is wrong, re-run: greens --setup"
      break
    fi
  done
fi

echo ""
info "By default, mirror commits contain only timestamps (no code or messages)."
printf "  Also copy commit messages to mirror? [y/N]: " >&2
read -r copy_msgs_reply
if [[ "$copy_msgs_reply" =~ ^[Yy] ]]; then
  copy_messages="1"
  warn "Commit messages from private repos will be visible in the public mirror."
else
  copy_messages="0"
  ok "Timestamps only (no message content exposed)"
fi

# ── Step 4: Mirror repo ────────────────────────────────────────────────────

mirror_dir="${MIRROR_DIR:-$CONFIG_DIR/mirror}"

# Validate mirror isn't inside work directory
resolved_mirror="$mirror_dir"
if parent="$(cd "$(dirname "$mirror_dir")" 2>/dev/null && pwd)"; then
  resolved_mirror="$parent/$(basename "$mirror_dir")"
fi
resolved_work=""
if [[ -n "$work_dir" ]]; then
  resolved_work="$(cd "$work_dir" 2>/dev/null && pwd)" || resolved_work="$work_dir"
fi
if [[ -n "$resolved_work" ]] && [[ "$resolved_mirror" == "$resolved_work" || "$resolved_mirror" == "$resolved_work/"* ]]; then
  echo ""
  warn "Mirror directory ($mirror_dir) is inside your work directory ($work_dir)."
  warn "This will cause the sync to scan the mirror as a work repo."
  info "Using default location: $CONFIG_DIR/mirror"
  mirror_dir="$CONFIG_DIR/mirror"
fi

echo ""
info "The mirror repo is where your contribution dots appear on GitHub."
info "It can be public or private. If private, enable 'Private contributions'"
info "in GitHub Settings > Profile so the green squares show on your profile."
echo ""
if [[ ! -d "$mirror_dir/.git" ]]; then
  mirror_repo_name="$(prompt "Repo name" "work-contributions-mirror")"

  # Try to auto-detect personal SSH identity for the mirror
  personal_host=""
  personal_user=""
  if [[ "$auth_method" == "ssh" ]]; then
    info "Detecting your personal GitHub account from SSH config..."
    if detect_personal_ssh "${github_username:-}" "${detected_ssh_host:-}"; then
      personal_host="$PERSONAL_SSH_HOST"
      personal_user="$PERSONAL_GH_USER"
      ok "Found personal account: $personal_user (SSH host: $personal_host)"
    fi
  fi

  if [[ -n "$personal_user" && -n "$personal_host" ]]; then
    # SSH multi-account: auto-construct mirror URL using personal identity
    mirror_url="git@${personal_host}:${personal_user}/${mirror_repo_name}.git"
    info "Mirror URL: $mirror_url"
    echo ""

    # Try to create the repo on GitHub
    repo_created=0
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
      gh_user="$(gh api user -q .login 2>/dev/null || echo "")"
      if [[ "$gh_user" == "$personal_user" ]]; then
        # gh is on the personal account, create directly
        if gh repo create "$mirror_repo_name" --public --description "Mirror of private work contributions" 2>/dev/null; then
          ok "Created github.com/$personal_user/$mirror_repo_name"
          repo_created=1
        fi
      fi
    fi

    if [[ "$repo_created" -eq 0 ]]; then
      echo ""
      info "Create this repo on your personal GitHub before continuing:"
      info "  https://github.com/new?name=$mirror_repo_name"
      echo ""
      info "Press Enter when done..."
      read -r
    fi
  elif command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    # Fallback: use gh CLI (single account or HTTPS)
    if confirm "Create a new public mirror repo on GitHub?"; then
      gh_user="$(gh api user -q .login 2>/dev/null || echo "")"
      if [[ -n "$gh_user" ]]; then
        # Check if gh is authenticated as work account
        is_work_account=0
        if [[ -n "${org_name:-}" && "$gh_user" == "$org_name" ]]; then
          is_work_account=1
        elif [[ -n "${github_username:-}" && "$gh_user" == "$github_username" ]]; then
          is_work_account=1
        fi

        if [[ "$is_work_account" -eq 1 ]]; then
          echo ""
          warn "gh is authenticated as '$gh_user', which matches your work account."
          warn "The mirror repo should be on your PERSONAL GitHub account."
          info "Switch accounts: gh auth login"
          echo ""
          if ! confirm "Create repo under $gh_user anyway?"; then
            mirror_url="$(prompt "Mirror repo URL (create it manually on your personal account)" "")"
            skip_gh_create=1
          fi
        else
          echo ""
          info "gh is authenticated as '$gh_user'."
          if ! confirm "Create repo under $gh_user?"; then
            mirror_url="$(prompt "Mirror repo URL (create it manually)" "")"
            skip_gh_create=1
          fi
        fi

        if [[ -z "${mirror_url:-}" && -z "${skip_gh_create:-}" ]]; then
          info "Creating github.com/$gh_user/$mirror_repo_name ..."
        fi
      fi
      if [[ -z "${mirror_url:-}" && -z "${skip_gh_create:-}" ]]; then
        if gh repo create "$mirror_repo_name" --public --description "Mirror of private work contributions" 2>/dev/null; then
          ok "Created repo on GitHub"
          if [[ "$auth_method" == "ssh" ]]; then
            mirror_url="$(gh repo view "$mirror_repo_name" --json sshUrl -q .sshUrl 2>/dev/null)"
          else
            mirror_url="$(gh repo view "$mirror_repo_name" --json url -q .url 2>/dev/null)"
          fi
        else
          warn "Couldn't create repo. Create it manually on GitHub."
          mirror_url="$(prompt "Mirror repo URL" "")"
        fi
      elif [[ -z "${mirror_url:-}" ]]; then
        mirror_url="$(prompt "Mirror repo URL (create it manually on your personal account)" "")"
      fi
    else
      mirror_url="$(prompt "Mirror repo URL (create an empty public repo on GitHub first)" "")"
    fi
  else
    mirror_url="$(prompt "Mirror repo URL (create an empty public repo on GitHub first)" "")"
  fi

  if [[ -n "${mirror_url:-}" ]]; then
    info "Cloning mirror repo..."
    git clone "$mirror_url" "$mirror_dir" 2>/dev/null || {
      info "Initializing new mirror repo..."
      mkdir -p "$mirror_dir"
      git -C "$mirror_dir" init --quiet
      git -C "$mirror_dir" remote add origin "$mirror_url"
    }
    # Ensure at least one commit exists (empty repos have no HEAD)
    if ! git -C "$mirror_dir" rev-parse --verify HEAD &>/dev/null; then
      git -C "$mirror_dir" commit --allow-empty -m "init" --quiet
    fi
    ok "Mirror repo ready at $mirror_dir"

    # Test push access
    echo ""
    info "Testing push access to mirror repo..."
    if git -C "$mirror_dir" push origin HEAD 2>/dev/null; then
      ok "Push access works"
    else
      warn "Can't push to mirror repo. Commits will be created locally but won't appear on GitHub."
      echo ""
      if [[ "$mirror_url" == https://* ]]; then
        fix_https_auth "$mirror_dir" "$mirror_url"
      else
        info "Check that your SSH key has access to push to this repo."
      fi
    fi
  fi
else
  ok "Mirror repo already exists at $mirror_dir"
  current_remote="$(git -C "$mirror_dir" remote get-url origin 2>/dev/null || echo "")"
  if [[ -n "$current_remote" ]]; then
    info "Current remote: $(mask_url "$current_remote")"
    echo ""

    # Test push access
    info "Testing push access..."
    if git -C "$mirror_dir" push origin HEAD 2>/dev/null; then
      ok "Push access works"
    else
      warn "Can't push to mirror repo."
      echo ""
      echo "  What would you like to do?" >&2
      echo "  1) Change the remote URL (wrong repo or deleted repo)" >&2
      echo "  2) Fix push authentication (HTTPS token)" >&2
      echo "  3) Skip (fix later)" >&2
      printf "  Choice [1]: " >&2
      read -r push_fix_choice
      push_fix_choice="${push_fix_choice:-1}"

      case "$push_fix_choice" in
        1)
          new_mirror_url="$(prompt "New mirror repo URL" "")"
          if [[ -n "$new_mirror_url" ]]; then
            git -C "$mirror_dir" remote set-url origin "$new_mirror_url"
            ok "Remote updated to $(mask_url "$new_mirror_url")"
            # Test push with new URL
            info "Testing push access..."
            if git -C "$mirror_dir" push origin HEAD 2>/dev/null; then
              ok "Push access works"
            elif [[ "$new_mirror_url" == https://* ]]; then
              warn "Can't push with new URL."
              fix_https_auth "$mirror_dir" "$new_mirror_url"
            else
              warn "Still can't push. Check SSH access to this repo."
            fi
          fi
          ;;
        2)
          if [[ "$current_remote" == https://* ]]; then
            fix_https_auth "$mirror_dir" "$current_remote"
          else
            info "Current remote uses SSH. Check that your SSH key has push access."
            info "Test: ssh -T git@github.com"
          fi
          ;;
        *)
          info "Skipping. Fix later: greens --setup"
          ;;
      esac
    fi
  else
    warn "No remote URL configured for mirror repo."
    new_mirror_url="$(prompt "Mirror repo URL" "")"
    if [[ -n "$new_mirror_url" ]]; then
      git -C "$mirror_dir" remote add origin "$new_mirror_url" 2>/dev/null || \
        git -C "$mirror_dir" remote set-url origin "$new_mirror_url"
      ok "Remote set to $(mask_url "$new_mirror_url")"
      # Test push access right away
      info "Testing push access..."
      if git -C "$mirror_dir" push origin HEAD 2>/dev/null; then
        ok "Push access works"
      elif [[ "$new_mirror_url" == https://* ]]; then
        warn "Can't push."
        fix_https_auth "$mirror_dir" "$new_mirror_url"
      else
        warn "Can't push. Check SSH access to this repo."
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler setup
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Set up automatic daily sync?"
echo "  1) launchd (macOS) - recommended"
echo "     Runs missed syncs when your Mac wakes up. Survives reboots."
echo "  2) cron"
echo "     Skips if your Mac was asleep/off at the scheduled time."
echo "  3) Skip — run manually with: greens"
printf "  Choice [1]: " >&2
read -r sched_choice
sched_choice="${sched_choice:-1}"

sync_hour="0"
if [[ "$sched_choice" == "1" || "$sched_choice" == "2" ]]; then
  default_sync_hour="${SYNC_HOUR:-0}"
  sync_hour="$(prompt "What hour to run daily sync? (0-23, 0=midnight)" "$default_sync_hour")"
  # Validate
  if ! [[ "$sync_hour" =~ ^[0-9]+$ ]] || [[ "$sync_hour" -gt 23 ]]; then
    warn "Invalid hour '$sync_hour', defaulting to 0 (midnight)"
    sync_hour="0"
  fi
fi

sync_path="$SCRIPT_DIR/sync.sh"

case "$sched_choice" in
  1)
    label="com.greens"
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
      <integer>$sync_hour</integer>
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
    ok "Daily sync scheduled via launchd (${sync_hour}:00)"
    ;;
  2)
    cron_line="0 $sync_hour * * * /bin/bash $sync_path >> $CONFIG_DIR/logs/sync.log 2>&1"
    mkdir -p "$CONFIG_DIR/logs"
    (crontab -l 2>/dev/null | grep -v "$sync_path"; echo "$cron_line") | crontab -
    ok "Daily sync scheduled via cron (${sync_hour}:00)"
    ;;
  *)
    info "Skipped. Run manually: greens"
    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Write config (after scheduler so sync_hour is set)
# ─────────────────────────────────────────────────────────────────────────────

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
MIRROR_EMAIL="\${MIRROR_EMAIL:-$mirror_email}"
ACTIVITY_TYPES="\${ACTIVITY_TYPES:-$activity_types}"
COPY_MESSAGES="\${COPY_MESSAGES:-$copy_messages}"
SINCE="\${SINCE:-$since}"
SYNC_HOUR="\${SYNC_HOUR:-$sync_hour}"
EOF

# Add token if provided during auth setup
if [[ -n "${DETECTED_TOKEN:-}" ]]; then
  cat >> "$CONFIG_FILE" << EOF
GITHUB_TOKEN="\${GITHUB_TOKEN:-$DETECTED_TOKEN}"
EOF
fi

echo ""
ok "Config saved to $CONFIG_FILE"

echo ""
ok "Setup complete!"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  IMPORTANT: Enable private contributions on GitHub          │"
echo "  │                                                             │"
echo "  │  Go to: https://github.com/settings/profile                │"
echo "  │  Scroll to 'Contributions' and check:                      │"
echo "  │    [x] Include private contributions on my profile          │"
echo "  │                                                             │"
echo "  │  Without this, your green squares won't show to visitors.   │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
