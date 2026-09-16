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
