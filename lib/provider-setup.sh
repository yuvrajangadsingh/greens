#!/bin/bash
# Automatic multi-directory, multi-provider setup. Sourced by setup.sh.

greens_required() {
  local value
  value="$(prompt "$1" "${2:-}")" || return 1
  [[ -n "$value" ]] || { echo "$1 is required." >&2; return 1; }
  printf '%s\n' "$value"
}

greens_source_value() {
  local key="SOURCE_${1}_${2}"
  printf '%s' "${!key:-}"
}

greens_existing_host_record() {
  local remote_host="$1" i aliases alias
  for ((i=1; i<=${SOURCE_COUNT:-0}; i++)); do
    aliases="$(greens_source_value "$i" REMOTE_HOSTS)"
    for alias in ${aliases//,/ }; do
      if [[ "$alias" == "$remote_host" ]]; then
        printf '%s\t%s\n' "$(greens_source_value "$i" PROVIDER)" "$(greens_source_value "$i" API_HOST)"
        return 0
      fi
    done
  done
  return 1
}

greens_probe_provider() {
  local domain="$1" body
  case "$domain" in github.com) printf 'github\n'; return ;; gitlab.com) printf 'gitlab\n'; return ;; esac
  if command -v gh >/dev/null 2>&1 && gh auth status --active --hostname "$domain" >/dev/null 2>&1 &&
     gh api --hostname "$domain" / --jq .current_user_url >/dev/null 2>&1; then
    printf 'github\n'; return
  fi
  if command -v glab >/dev/null 2>&1 && glab auth status --hostname "$domain" >/dev/null 2>&1 &&
     glab api --hostname "$domain" metadata >/dev/null 2>&1; then
    printf 'gitlab\n'; return
  fi
  command -v curl >/dev/null 2>&1 || return 1
  body="$(mktemp)"
  if GREENS_FETCH_TIMEOUT=10 greens_run curl -fsSL --max-time 10 "https://$domain/api/v3/" > "$body" 2>/dev/null &&
     jq -e '.current_user_url and .repository_url' "$body" >/dev/null 2>&1; then
    rm -f "$body"; printf 'github\n'; return
  fi
  if GREENS_FETCH_TIMEOUT=10 greens_run curl -fsSL --max-time 10 "https://$domain/api/v4/metadata" > "$body" 2>/dev/null &&
     jq -e '.version and .revision' "$body" >/dev/null 2>&1; then
    rm -f "$body"; printf 'gitlab\n'; return
  fi
  rm -f "$body"
  return 1
}

greens_validate_activity_types() {
  local provider="$1" values="$2" item
  for item in ${values//,/ }; do
    case "$provider:$item" in
      github:commits|github:prs|github:issues|github:reviews|\
      gitlab:commits|gitlab:mrs|gitlab:issues|gitlab:comments|gitlab:approvals|gitlab:merges|gitlab:state_changes|\
      git:commits) ;;
      *) fail "Unknown $provider activity type: $item"; return 1 ;;
    esac
  done
}

greens_normalize_activity_types() {
  local provider="$1" values="$2" item normalized=""
  for item in ${values//,/ }; do
    [[ "$provider" == gitlab && "$item" == prs ]] && item=mrs
    case ",$normalized," in *",$item,"*) continue ;; esac
    [[ -n "$normalized" ]] && normalized+=,
    normalized+="$item"
  done
  printf '%s\n' "$normalized"
}

greens_show_existing_config() {
  local i
  info "Current configuration:"
  if [[ -n "${WORK_DIRS:-}" ]]; then
    while IFS= read -r dir; do [[ -n "$dir" ]] && info "  Work directory: $dir"; done <<< "$WORK_DIRS"
  elif [[ -n "${WORK_DIR:-}" ]]; then info "  Work directory: $WORK_DIR (legacy)"; fi
  if [[ "${SOURCE_COUNT:-0}" -gt 0 ]]; then
    for ((i=1; i<=SOURCE_COUNT; i++)); do
      info "  Source $i: $(greens_source_value "$i" PROVIDER)://$(greens_source_value "$i" API_HOST)/$(greens_source_value "$i" ORGANIZATION)"
      info "    activity=$(greens_source_value "$i" ACTIVITY_TYPES), since=$(greens_source_value "$i" SINCE)"
    done
  elif [[ -n "${SOURCE_PROVIDER:-}" || -n "${REMOTE_PREFIX:-}" ]]; then
    info "  Source: ${SOURCE_PROVIDER:-github} (legacy configuration)"
  fi
  info "  Mirror: ${MIRROR_URL:-${MIRROR_DIR:-not configured}}"
  info "  Scan mode: ${SCAN_MODE:-recursive}"
  info "  Scheduler: ${SCHEDULER:-legacy/default}"
}

greens_sources_setup() {
  local had_config=0 legacy_schema=0 existing_dirs suggested_dir="" dirs="" path canonical answer setup_tmp
  local scan hosts class groups gitpath repodir url identity host rest organization
  local record provider api domain detected choice ssh_domain existing_source_count existing_sources
  local aliases username emails since types defaults meta i key owner branch default_email personal_default
  local -a save_keys
  for key in git jq gh; do command -v "$key" >/dev/null || { fail "Install $key, then rerun setup."; return 1; }; done
  existing_source_count="${SOURCE_COUNT:-0}"
  if [[ -f "$CONFIG_FILE" ]]; then
    had_config=1; greens_show_existing_config; echo "" >&2
    answer="$(prompt 'Rerun setup using these values as defaults? (y/N)' 'n')"
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
  fi
  if [[ "$had_config" == 1 && "$existing_source_count" -eq 0 &&
        ( -n "${WORK_DIR:-}" || -n "${SOURCE_PROVIDER:-}" || -n "${REMOTE_PREFIX:-}" ) ]]; then
    legacy_schema=1
  fi

  existing_dirs="${WORK_DIRS:-${WORK_DIR:-}}"
  if [[ -n "$existing_dirs" ]]; then
    dirs="$existing_dirs"
    info "Repository roots (kept by default):"
    while IFS= read -r path; do [[ -n "$path" ]] && info "  $path"; done <<< "$existing_dirs"
  else
    suggested_dir="$(detect_work_dir)"
  fi
  info "Add repository roots one at a time. Press Enter when every root is listed."
  while true; do
    if [[ -n "$dirs" ]]; then
      path="$(prompt 'Add another work directory (blank to finish)' '')" || return 1
    else
      path="$(prompt 'Work directory' "$suggested_dir")" || return 1
    fi
    [[ -n "$path" ]] || { [[ -n "$dirs" ]] && break; warn "At least one directory is required."; continue; }
    path="${path/#\~/$HOME}"
    [[ -d "$path" ]] || { warn "Directory does not exist: $path"; continue; }
    canonical="$(cd "$path" && pwd -P)"
    if ! printf '%s\n' "$dirs" | grep -qxF "$canonical"; then
      [[ -n "$dirs" ]] && dirs+=$'\n'
      dirs+="$canonical"
      ok "Added $canonical"
    fi
  done
  WORK_DIRS="$dirs"

  setup_tmp="$(mktemp -d)"
  GREENS_SETUP_TMP="$setup_tmp"
  trap '[[ -z "${GREENS_SETUP_TMP:-}" ]] || rm -rf -- "$GREENS_SETUP_TMP"' EXIT
  scan="$setup_tmp/scan"; hosts="$setup_tmp/hosts"; class="$setup_tmp/class"; groups="$setup_tmp/groups"; : > "$scan"
  while IFS= read -r path; do
    [[ -d "$path" ]] || { warn "Configured work directory is unavailable: $path"; continue; }
    while IFS= read -r -d '' gitpath; do
      repodir="$(dirname "$gitpath")"; url="$(git -C "$repodir" config remote.origin.url 2>/dev/null || true)"
      identity="$(greens_remote_identity "$url")" || continue
      host="${identity%%/*}"; rest="${identity#*/}"; organization="${rest%%/*}"
      printf '%s\t%s\t%s\t%s\n' "$host" "$organization" "$identity" "$repodir" >> "$scan"
    done < <(greens_find_git_entries "$path" "$SCAN_MODE")
  done <<< "$WORK_DIRS"
  LC_ALL=C sort -u "$scan" -o "$scan"
  [[ -s "$scan" ]] || { fail "No repositories with an origin remote were found."; return 1; }
  cut -f1 "$scan" | sort -u > "$hosts"

  while IFS= read -r host <&4; do
    if record="$(greens_existing_host_record "$host" 2>/dev/null)"; then
      provider="${record%%$'\t'*}"; api="${record#*$'\t'}"; printf '%s\t%s\t%s\n' "$host" "$provider" "$api" >> "$class"; continue
    fi
    if [[ "$existing_source_count" -eq 0 && "${SOURCE_PROVIDER:-github}" == gitlab &&
          ( "$host" == "${GITLAB_REMOTE_HOST:-${GITLAB_HOST:-gitlab.com}}" || "$host" == "${GITLAB_HOST:-gitlab.com}" ) ]]; then
      printf '%s\tgitlab\t%s\n' "$host" "${GITLAB_HOST:-$host}" >> "$class"
      continue
    fi
    if [[ "$existing_source_count" -eq 0 && "${SOURCE_PROVIDER:-github}" == git && "${REMOTE_PREFIX:-}" == *"$host"* ]]; then
      printf '%s\tgit\t%s\n' "$host" "$host" >> "$class"
      continue
    fi
    case "$host" in github.com) provider=github; api=github.com ;; gitlab.com) provider=gitlab; api=gitlab.com ;;
      *)
        ssh_domain="$(ssh -G "$host" 2>/dev/null | awk 'tolower($1)=="hostname" {print $2; exit}')"
        domain="$(greens_required "Web/API domain for remote host $host" "${ssh_domain:-$host}")"
        domain="${domain#https://}"; domain="${domain#http://}"; domain="${domain%/}"
        if detected="$(greens_probe_provider "$domain")"; then provider="$detected"; api="$domain"; ok "$host detected as $provider ($api)"
        else
          info "Could not identify $domain. Choose: 1) GitHub Enterprise  2) GitLab  3) generic Git  4) ignore"
          choice="$(prompt 'Choice' '3')"
          case "$choice" in 1) provider=github; api="$domain" ;; 2) provider=gitlab; api="$domain" ;; 4) continue ;; *) provider=git; api="$domain" ;; esac
        fi ;;
    esac
    printf '%s\t%s\t%s\n' "$host" "$provider" "$api" >> "$class"
  done 4< "$hosts"

  awk -F '\t' 'NR==FNR {p[$1]=$2; a[$1]=$3; next} ($1 in p) {key=p[$1] FS a[$1] FS $2; repo=a[$1] "/" substr($3,index($3,"/")+1); unique=key SUBSEP repo; if(!(unique in seen)){seen[unique]=1; count[key]++} if(hosts[key]=="")hosts[key]=$1; else if("," hosts[key] "," !~ "," $1 ",")hosts[key]=hosts[key] "," $1} END {for(key in count)print key FS hosts[key] FS count[key]}' "$class" "$scan" | LC_ALL=C sort > "$groups"

  # A disconnected drive or temporarily missing clone must not silently erase
  # a previously configured source during setup.
  for ((i=1; i<=${SOURCE_COUNT:-0}; i++)); do
    provider="$(greens_source_value "$i" PROVIDER)"; api="$(greens_source_value "$i" API_HOST)"; organization="$(greens_source_value "$i" ORGANIZATION)"
    if ! awk -F '\t' -v p="$provider" -v a="$api" -v o="$organization" '$1==p && $2==a && $3==o {found=1} END {exit !found}' "$groups"; then
      warn "Configured source is not currently detected; retaining $provider $api/$organization."
      printf '%s\t%s\t%s\t%s\t0\n' "$provider" "$api" "$organization" "$(greens_source_value "$i" REMOTE_HOSTS)" >> "$groups"
    fi
  done

  existing_sources="$setup_tmp/existing-sources"
  : > "$existing_sources"
  for ((i=1; i<=existing_source_count; i++)); do
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "$(greens_source_value "$i" PROVIDER)" "$(greens_source_value "$i" API_HOST)" "$(greens_source_value "$i" ORGANIZATION)" \
      "$(greens_source_value "$i" USERNAME)" "$(greens_source_value "$i" EMAILS)" "$(greens_source_value "$i" SINCE)" "$(greens_source_value "$i" ACTIVITY_TYPES)" >> "$existing_sources"
  done
  SOURCE_COUNT=0
  while IFS=$'\t' read -r provider api organization aliases _count <&4; do
    username=""; emails=""; since=""; types=""
    record="$(awk -F '|' -v p="$provider" -v a="$api" -v o="$organization" '$1==p && $2==a && $3==o {print; exit}' "$existing_sources")"
    if [[ -n "$record" ]]; then IFS='|' read -r _ _ _ username emails since types <<< "$record"; fi
    if [[ -z "$record" && "$existing_source_count" -eq 0 ]]; then
      emails="${EMAILS:-}"; since="${SINCE:-}"; types="${ACTIVITY_TYPES:-}"
      if [[ "$provider" == github ]]; then username="${GITHUB_USERNAME:-}"; elif [[ "$provider" == gitlab ]]; then username="${GITLAB_USERNAME:-}"; fi
    fi
    while true; do
      emails="$(prompt "Git author emails for $api/$organization (comma-separated, or - to skip all $_count repositories)" "${emails:-$(detect_emails)}")" || return 1
      emails="$(printf '%s' "$emails" | tr -d '[:space:]')"
      [[ -n "$emails" ]] && break
      warn "Author emails are required; enter - to skip this source group."
    done
    if [[ "$emails" == - ]]; then
      info "Skipping $provider $api/$organization ($_count repositories)."
      continue
    fi
    SOURCE_COUNT="$((SOURCE_COUNT + 1))"
    if [[ "$provider" == github ]]; then
      gh auth status --active --hostname "$api" >/dev/null 2>&1 || { fail "Run gh auth login --hostname $api first."; return 1; }
      meta="$(greens_gh_api_as "$api" "" user)" || return 1
      username="$(greens_required "GitHub username for $api/$organization" "${username:-$(jq -r .login <<< "$meta")}")"
      meta="$(greens_gh_api_as "$api" "$username" user)" || return 1
      [[ "$username" == "$(jq -r .login <<< "$meta")" ]] || { fail "Authenticate gh as $username on $api first."; return 1; }
      defaults=commits,prs,issues
    elif [[ "$provider" == gitlab ]]; then
      command -v glab >/dev/null || { fail "Install glab and authenticate $api."; return 1; }
      meta="$(glab api --hostname "$api" user)" || { fail "Run glab auth login --hostname $api first."; return 1; }
      username="$(greens_required "GitLab username for $api/$organization" "${username:-$(jq -r .username <<< "$meta")}")"
      [[ "$username" == "$(jq -r .username <<< "$meta")" ]] || { fail "Authenticate glab as $username on $api first."; return 1; }
      defaults=commits,mrs,issues,comments,approvals,merges,state_changes
    else defaults=commits; fi
    types="$(greens_normalize_activity_types "$provider" "$types")"
    since="$(greens_required "Include $api/$organization activity since" "${since:-$(date +%Y)-01-01}")"; greens_epoch "$since" >/dev/null || { fail "Invalid history start for $api/$organization."; return 1; }
    if [[ "$provider" == git ]]; then types=commits; else types="$(greens_required "Activity types for $api/$organization" "${types:-$defaults}")"; fi
    greens_validate_activity_types "$provider" "$types" || return 1
    printf -v "SOURCE_${SOURCE_COUNT}_PROVIDER" '%s' "$provider"; printf -v "SOURCE_${SOURCE_COUNT}_REMOTE_HOSTS" '%s' "$aliases"
    printf -v "SOURCE_${SOURCE_COUNT}_API_HOST" '%s' "$api"; printf -v "SOURCE_${SOURCE_COUNT}_ORGANIZATION" '%s' "$organization"
    printf -v "SOURCE_${SOURCE_COUNT}_USERNAME" '%s' "$username"; printf -v "SOURCE_${SOURCE_COUNT}_EMAILS" '%s' "$emails"
    printf -v "SOURCE_${SOURCE_COUNT}_SINCE" '%s' "$since"; printf -v "SOURCE_${SOURCE_COUNT}_ACTIVITY_TYPES" '%s' "$types"
  done 4< "$groups"

  [[ "$SOURCE_COUNT" -gt 0 ]] || { fail "Every detected source group was skipped; the existing configuration was not changed."; return 1; }

  info "Detected source configuration:"
  for ((i=1; i<=SOURCE_COUNT; i++)); do info "  $(greens_source_value "$i" PROVIDER) $(greens_source_value "$i" API_HOST)/$(greens_source_value "$i" ORGANIZATION): $(greens_source_value "$i" ACTIVITY_TYPES)"; done
  personal_default="${PERSONAL_GH_USER:-$(gh api --hostname github.com user --jq .login)}"
  PERSONAL_GH_USER="$(greens_required 'Personal GitHub username' "$personal_default")"
  gh auth switch --hostname github.com --user "$PERSONAL_GH_USER" >/dev/null 2>&1 || { fail "Run gh auth login --hostname github.com for $PERSONAL_GH_USER first."; return 1; }
  default_email="$(gh api --hostname github.com user/emails --jq '.[] | select(.verified and .primary) | .email' 2>/dev/null || true)"
  MIRROR_EMAIL="$(greens_required 'Personal GitHub email' "${MIRROR_EMAIL:-$default_email}")"; MIRROR_NAME="$(greens_required 'Mirror author name' "${MIRROR_NAME:-greens}")"
  MIRROR_URL="$(greens_required 'GitHub mirror URL' "${MIRROR_URL:-https://github.com/$PERSONAL_GH_USER/work-contributions-mirror}")"
  owner="$(greens_remote_identity "$MIRROR_URL")" || { fail "Invalid mirror URL."; return 1; }; [[ "$owner" == github.com/"$PERSONAL_GH_USER"/* ]] || { fail "Choose a github.com repository owned by $PERSONAL_GH_USER."; return 1; }; owner="${owner#github.com/}"
  if ! meta="$(gh api "repos/$owner" 2>/dev/null)"; then confirm "Create private GitHub repository $owner?" || return 1; gh repo create "$owner" --private --description "Timestamp-only work contribution mirror"; meta="$(gh api "repos/$owner")"; fi
  if [[ "$(jq -r .private <<< "$meta")" != true ]]; then warn "This public mirror exposes exact work timestamps."; [[ "$(prompt 'Type PUBLIC to use this public mirror' '')" == PUBLIC ]] || return 1; fi
  branch="$(jq -er .default_branch <<< "$meta")"; MIRROR_DIR="$(greens_required 'Local mirror directory' "${MIRROR_DIR:-$CONFIG_DIR/mirror}")"; MIRROR_DIR="${MIRROR_DIR/#\~/$HOME}"
  mkdir -p "$(dirname "$MIRROR_DIR")"; MIRROR_DIR="$(cd "$(dirname "$MIRROR_DIR")" && pwd)/$(basename "$MIRROR_DIR")"
  while IFS= read -r path; do case "$MIRROR_DIR/" in "$path/"*) fail "Choose a mirror directory outside every work directory."; return 1 ;; esac; done <<< "$WORK_DIRS"
  if [[ ! -d "$MIRROR_DIR/.git" ]]; then git clone "$MIRROR_URL" "$MIRROR_DIR"; elif [[ "$(greens_remote_identity "$(git -C "$MIRROR_DIR" config remote.origin.url)")" != "github.com/$owner" ]]; then fail "Existing mirror has a different origin."; return 1; fi
  if ! git -C "$MIRROR_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then git -C "$MIRROR_DIR" symbolic-ref HEAD "refs/heads/$branch"; fi
  # Passed by variable name to greens_replace_config.
  # shellcheck disable=SC2034
  COPY_MESSAGES=0 COPY_MESSAGES_ACK=0
  SCHEDULER="$(greens_required 'Scheduler (systemd, cron, or manual)' "${SCHEDULER:-$([[ "$(uname -s)" == Linux ]] && echo systemd || echo manual)}")"; case "$SCHEDULER" in systemd|cron|manual) ;; *) fail "Choose systemd, cron, or manual."; return 1 ;; esac
  SYNC_HOUR="$(greens_required 'Daily hour (0-23, local timezone)' "${SYNC_HOUR:-0}")"; [[ "$SYNC_HOUR" =~ ^[0-9]{1,2}$ ]] && [[ "$((10#$SYNC_HOUR))" -le 23 ]] || { fail "Invalid hour."; return 1; }; SYNC_HOUR="$((10#$SYNC_HOUR))"
  # Passed by variable name to greens_replace_config.
  # shellcheck disable=SC2034
  GREENS_LEGACY_TIMESTAMPS=0
  # shellcheck disable=SC2034
  if [[ "$legacy_schema" == 1 && -d "$MIRROR_DIR/.git" ]] && git -C "$MIRROR_DIR" rev-parse --verify HEAD >/dev/null 2>&1 && ! git -C "$MIRROR_DIR" log --format=%B | grep -q '^Greens-Activity: '; then printf -v GREENS_LEGACY_TIMESTAMPS '%s' 1; fi
  save_keys=(WORK_DIRS SCAN_MODE SOURCE_COUNT PERSONAL_GH_USER MIRROR_EMAIL MIRROR_NAME MIRROR_URL MIRROR_DIR COPY_MESSAGES COPY_MESSAGES_ACK SCHEDULER SYNC_HOUR GREENS_LEGACY_TIMESTAMPS)
  for ((i=1; i<=SOURCE_COUNT; i++)); do for key in PROVIDER REMOTE_HOSTS API_HOST ORGANIZATION USERNAME EMAILS SINCE ACTIVITY_TYPES; do save_keys+=("SOURCE_${i}_${key}"); done; done
  greens_replace_config "$CONFIG_FILE" '^(WORK_DIRS?|SCAN_MODE|SOURCE_PROVIDER|SOURCE_COUNT|SOURCE_[0-9]+_.*|REMOTE_PREFIX|GITHUB_(ORG|USERNAME|TOKEN)|GITLAB_(HOST|REMOTE_HOST|USERNAME)|EMAILS|SINCE|ACTIVITY_TYPES)$' "${save_keys[@]}"
  ok "Saved configuration to $CONFIG_FILE"
  if confirm "Run the initial sync now?"; then FORCE=1 CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$SCRIPT_DIR/sync.sh"; fi
  if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$(greens_scheduler_id).timer" ]]; then greens_systemd_remove; fi
  greens_remove_cron; case "$SCHEDULER" in systemd) greens_install_systemd "$SCRIPT_DIR/sync.sh" "$SYNC_HOUR" ;; cron) greens_install_cron "$SCRIPT_DIR/sync.sh" "$SYNC_HOUR" ;; esac
  ok "Setup complete. Run greens --status to inspect configuration and scheduling."
}

greens_provider_setup() { greens_sources_setup; }
