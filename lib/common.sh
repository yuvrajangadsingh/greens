#!/bin/bash
# Shared by setup, the CLI, and tests. Compatible with macOS Bash 3.2.

greens_config_path() {
  local file="$1" parent
  [[ "$file" == /* ]] || file="$PWD/$file"
  if parent="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)"; then
    file="$parent/$(basename "$file")"
  fi
  printf '%s\n' "$file"
}

# Load the latest assignment for each configuration key. Older greens versions
# could append a new default without removing an earlier assignment, causing the
# earlier value to win through shell default-expansion syntax.
greens_source_config() {
  local file="$1"
  # shellcheck disable=SC1090
  source <(awk '
    function config_key(line, clean) {
      clean=line
      sub(/^[[:space:]]*export[[:space:]]+/, "", clean)
      if (clean !~ /^[A-Z][A-Z0-9_]*=/) return ""
      sub(/=.*/, "", clean)
      return clean
    }
    NR==FNR { key=config_key($0); if (key != "") last[key]=FNR; next }
    { key=config_key($0); if (key != "" && last[key] != FNR) next; print }
  ' "$file" "$file")
}

greens_stamp_path() {
  local dir="${LOG_DIR:-$HOME/.contrib-mirror/logs}"
  if [[ "$CONFIG_FILE" == "$HOME/.contrib-mirror/config" ]]; then
    printf '%s/last-success-date\n' "$dir"
  else
    printf '%s/%s-last-success-date\n' "$dir" "$(greens_scheduler_id)"
  fi
}

greens_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

greens_indexed_value() {
  local key="SOURCE_${1}_${2}"
  printf '%s' "${!key:-}"
}

greens_validate_scan_mode() {
  case "$1" in recursive|in-root) return 0 ;; esac
  echo "Invalid SCAN_MODE '$1'; expected recursive or in-root." >&2
  return 1
}

# Print NUL-delimited paths to repository .git entries. In in-root mode only
# immediate child folders of the configured root are eligible; the root itself
# and deeper descendants are intentionally ignored.
greens_find_git_entries() {
  local root="$1" mode="${2:-recursive}"
  greens_validate_scan_mode "$mode" || return 1
  [[ -d "$root" ]] || return 0
  if [[ "$mode" == in-root ]]; then
    find "$root" -mindepth 2 -maxdepth 2 -name .git -print0 2>/dev/null
  else
    find "$root" -name .git -print0 -prune 2>/dev/null
  fi
}

greens_count_repositories() {
  local root="$1" mode="${2:-recursive}" gitpath repodir url identity key existing duplicate count=0
  local -a seen=()
  while IFS= read -r -d '' gitpath; do
    repodir="$(dirname "$gitpath")"
    url="$(git -C "$repodir" config remote.origin.url 2>/dev/null || true)"
    if identity="$(greens_remote_identity "$url" 2>/dev/null)"; then key="origin:$identity"; else key="path:$repodir"; fi
    duplicate=0
    for existing in "${seen[@]}"; do [[ "$existing" == "$key" ]] && { duplicate=1; break; }; done
    [[ "$duplicate" == 1 ]] && continue
    seen+=("$key")
    count="$((count + 1))"
  done < <(greens_find_git_entries "$root" "$mode")
  printf '%s\n' "$count"
}

# Run one GitHub API request as a configured account, then restore the account
# that was active for that host. gh selects accounts per host rather than per
# command, so this keeps multiple owners and a personal destination account
# from changing each other's authentication context.
greens_gh_api_as() {
  local host="$1" user="$2" active switched=0 rc
  shift 2
  active="$(greens_run gh api --hostname "$host" user --jq .login 2>/dev/null)" || return 1
  if [[ -n "$user" && "$user" != "$active" ]]; then
    gh auth switch --hostname "$host" --user "$user" >/dev/null 2>&1 || {
      echo "GitHub account '$user' is not authenticated for $host. Run: gh auth login --hostname $host" >&2
      return 1
    }
    switched=1
  fi
  if greens_run gh api --hostname "$host" "$@"; then rc=0; else rc=$?; fi
  if [[ "$switched" == 1 ]] && ! gh auth switch --hostname "$host" --user "$active" >/dev/null 2>&1; then
    echo "Could not restore GitHub account '$active' for $host." >&2
    return 1
  fi
  return "$rc"
}

greens_run() {
  local seconds="${GREENS_FETCH_TIMEOUT:-120}"
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=10 "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV or die $!' "$seconds" "$@"
  else
    echo "A timeout utility or Perl is required for bounded network requests." >&2
    return 1
  fi
}

greens_save_config() {
  local file="$1" key tmp
  shift
  umask 077
  [[ ! -L "$file" ]] || { echo "Refusing to replace a symlink config: $file" >&2; return 1; }
  [[ ! -e "$file" || -O "$file" ]] || return 1
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  chmod 600 "$tmp"
  if [[ -f "$file" ]]; then cat "$file" > "$tmp"; fi
  for key in "$@"; do
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    # Defaults are shell-escaped, never evaluated while writing or reloading.
    awk -v key="$key" '$0 !~ ("^[[:space:]]*(export[[:space:]]+)?" key "=")' "$tmp" > "$tmp.next"
    mv "$tmp.next" "$tmp"
    printf '%s=${%s-%q}\n' "$key" "$key" "${!key}" >> "$tmp"
  done
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

# Atomically replace all managed configuration keys matching a regular
# expression, then write the supplied variables using the same environment
# override semantics as greens_save_config. This lets setup migrate schemas
# without leaving stale indexed or legacy keys behind.
greens_replace_config() {
  local file="$1" managed="$2" key tmp
  shift 2
  umask 077
  [[ ! -L "$file" ]] || { echo "Refusing to replace a symlink config: $file" >&2; return 1; }
  [[ ! -e "$file" || -O "$file" ]] || return 1
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  chmod 600 "$tmp"
  if [[ -f "$file" ]]; then
    awk -v managed="$managed" '
      {
        line=$0
        sub(/^[[:space:]]*export[[:space:]]+/, "", line)
        key=line
        sub(/=.*/, "", key)
        if (key !~ managed) print $0
      }' "$file" > "$tmp"
  fi
  for key in "$@"; do
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    printf '%s=${%s-%q}\n' "$key" "$key" "${!key}" >> "$tmp"
  done
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

greens_epoch() {
  local value="$1"
  date -d "$value" +%s 2>/dev/null && return
  case "$value" in ????-??-??) value="$value 00:00:00" ;; esac
  date -j -f '%Y-%m-%d %H:%M:%S' "$value" +%s 2>/dev/null
}

greens_utc_date() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
    date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

# Canonical host/path, without credentials, transport, or a trailing .git.
# The original URL is retained for Git operations (including SSH aliases/ports).
greens_remote_identity() {
  local url="$1" authority path
  case "$url" in
    *://*)
      url="${url#*://}"
      authority="${url%%/*}"
      path="${url#*/}"
      authority="${authority##*@}"
      authority="${authority%%:*}"
      ;;
    *:*)
      authority="${url%%:*}"
      authority="${authority##*@}"
      path="${url#*:}"
      ;;
    *) return 1 ;;
  esac
  path="${path#/}"; path="${path%/}"; path="${path%.git}"
  [[ -n "$authority" && "$path" == */* && "$path" != *$'\t'* && "$path" != *$'\n'* ]] || return 1
  printf '%s/%s\n' "$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')" "$path"
}

greens_scheduler_id() {
  local hash
  hash="$(printf '%s' "$CONFIG_FILE" | greens_hash)"
  printf 'greens-%s' "${hash:0:12}"
}

greens_systemd_remove() {
  local id dir
  id="$(greens_scheduler_id)"
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  systemctl --user disable --now "$id.timer" 2>/dev/null || true
  systemctl --user stop "$id.service" 2>/dev/null || true
  rm -f "$dir/$id.timer" "$dir/$id.service" "$(dirname "$CONFIG_FILE")/$id-run"
  systemctl --user daemon-reload
}

greens_install_systemd() {
  local script="$1" hour="$2" id dir runner escaped
  command -v systemctl >/dev/null || { echo "systemd is unavailable; choose cron or manual." >&2; return 1; }
  systemctl --user show-environment >/dev/null || return 1
  id="$(greens_scheduler_id)"
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  runner="$(dirname "$CONFIG_FILE")/$id-run"
  mkdir -p "$dir"
  {
    echo '#!/bin/bash'
    printf 'export CONTRIB_MIRROR_CONFIG=%q\n' "$CONFIG_FILE"
    printf 'export PATH=%q\n' "$PATH"
    printf 'exec /bin/bash %q\n' "$script"
  } > "$runner"
  chmod 700 "$runner"
  escaped="${runner//\\/\\\\}"; escaped="${escaped//\"/\\\"}"
  escaped="${escaped//%/%%}"; escaped="${escaped//\$/\$\$}"
  cat > "$dir/$id.service" <<EOF
[Unit]
Description=greens contribution mirror
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/bin/bash "$escaped"
UMask=0077
Restart=on-failure
RestartSec=15min
EOF
  cat > "$dir/$id.timer" <<EOF
[Unit]
Description=Daily greens contribution sync

[Timer]
OnCalendar=*-*-* $(printf '%02d' "$hour"):00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$id.timer"
}

greens_install_cron() {
  local script="$1" hour="$2" id line
  id="$(greens_scheduler_id)"
  printf -v line '0 %s * * * CONTRIB_MIRROR_CONFIG=%q /bin/bash %q >> %q 2>&1 # %s' \
    "$hour" "$CONFIG_FILE" "$script" "${LOG_DIR:-$HOME/.contrib-mirror/logs}/sync.log" "$id"
  line="${line//%/\\%}"
  mkdir -p "${LOG_DIR:-$HOME/.contrib-mirror/logs}"
  { crontab -l 2>/dev/null | grep -v "# $id$" || true; echo "$line"; } | crontab -
}

greens_remove_cron() {
  local id tmp
  command -v crontab >/dev/null || return 0
  id="$(greens_scheduler_id)"
  tmp="$(mktemp)"
  if crontab -l > "$tmp" 2>/dev/null && grep -q "# $id$" "$tmp"; then
    { grep -v "# $id$" "$tmp" || true; } | crontab -
  fi
  rm -f "$tmp"
}
