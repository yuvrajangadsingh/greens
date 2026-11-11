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
  local file="$1" filtered rc
  # Bash 3.2 reads sourced files by stat size; a Linux process-substitution
  # pipe has size zero. Use a private regular file for the filtered config.
  filtered="$(mktemp)" || return 1
  awk '
    function config_key(line, clean) {
      clean=line
      sub(/^[[:space:]]*export[[:space:]]+/, "", clean)
      if (clean !~ /^[A-Z][A-Z0-9_]*=/) return ""
      sub(/=.*/, "", clean)
      return clean
    }
    NR==FNR { key=config_key($0); if (key != "") last[key]=FNR; next }
    { key=config_key($0); if (key != "" && last[key] != FNR) next; print }
  ' "$file" "$file" > "$filtered" || { rm -f "$filtered"; return 1; }
  # shellcheck disable=SC1090
  if source "$filtered"; then rc=0; else rc=$?; fi
  rm -f "$filtered"
  return "$rc"
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
  local key="SOURCE_${1}_${2}" provider_key="SOURCE_${1}_PROVIDER"
  if [[ "$2" == ORGANIZATION ]]; then
    greens_provider_identity "${!provider_key:-git}" "${!key:-}"
  else
    printf '%s' "${!key:-}"
  fi
}

# Apply path rules after provider classification. GitHub owners/repositories
# are insensitive to case; GitLab and generic Git retain their original paths.
greens_provider_identity() {
  if [[ "$1" == github ]]; then
    printf '%s' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]'
  else
    printf '%s' "$2"
  fi
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
    if identity="$(greens_remote_identity "$url" 0 "$repodir" 2>/dev/null)"; then key="origin:$identity"; else key="path:$repodir"; fi
    duplicate=0
    for existing in ${seen[@]+"${seen[@]}"}; do [[ "$existing" == "$key" ]] && { duplicate=1; break; }; done
    [[ "$duplicate" == 1 ]] && continue
    seen+=("$key")
    count="$((count + 1))"
  done < <(greens_find_git_entries "$root" "$mode")
  printf '%s\n' "$count"
}

# GitHub logins are case-insensitive, including saved configuration values.
greens_gh_same_account() {
  [[ -n "$1" && -n "$2" && "$(greens_provider_identity github "$1")" == "$(greens_provider_identity github "$2")" ]]
}

greens_gh_token_actor() (
  local host="$1" token="$2"
  export GH_HOST="$host" GH_TOKEN="$token" GITHUB_TOKEN="$token"
  export GH_ENTERPRISE_TOKEN="$token" GITHUB_ENTERPRISE_TOKEN="$token"
  greens_run gh api --hostname "$host" user --jq .login
)

greens_gh_token() (
  local host="$1" user="$2" environment_fallback="${3:-1}" token="" candidate="" actor="" login logins
  if [[ "$environment_fallback" == 1 ]]; then
    case "$host" in
      github.com|*.ghe.com) candidate="${GH_TOKEN:-${GITHUB_TOKEN:-}}" ;;
      *) candidate="${GH_ENTERPRISE_TOKEN:-${GITHUB_ENTERPRISE_TOKEN:-}}" ;;
    esac
    # A matching explicit PAT may carry scopes/SSO grants absent from gh's
    # saved token. Never lend an unrelated ambient work PAT to the mirror.
    if [[ -n "$candidate" ]]; then
      if [[ -z "$user" ]]; then printf '%s' "$candidate"; return; fi
      actor="$(greens_gh_token_actor "$host" "$candidate" 2>/dev/null)" || actor=""
      if greens_gh_same_account "$actor" "$user"; then printf '%s' "$candidate"; return; fi
    fi
  fi
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
  if [[ -n "$user" ]]; then
    token="$(greens_run gh auth token --hostname "$host" --user "$user" 2>/dev/null)" || token=""
    if [[ -z "$token" ]]; then
      # gh's --user lookup is case-sensitive. Resolve to its stored spelling;
      # JSON status also lists accounts when the active account has expired.
      logins="$(greens_run gh auth status --hostname "$host" --json hosts --jq '.hosts[][] | .login' 2>/dev/null)" || logins=""
      if [[ -z "$logins" ]]; then
        # Multi-account gh versions predating JSON auth status.
        logins="$( { greens_run gh auth status --hostname "$host" 2>&1 || true; } |
          awk '{for(i=1;i<NF;i++) if($i=="account") print $(i+1)}')"
      fi
      while IFS= read -r login; do
        if greens_gh_same_account "$login" "$user"; then
          token="$(greens_run gh auth token --hostname "$host" --user "$login" 2>/dev/null)" || token=""
          break
        fi
      done <<< "$logins"
    fi
  else
    token="$(greens_run gh auth token --hostname "$host" 2>/dev/null)" || token=""
  fi
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
)

# Keep credentials local to one command. Named account lookup does not depend
# on the active account and never changes gh's shared authentication state.
greens_gh_as() (
  local host="$1" user="$2" token="${GREENS_COMMAND_GH_TOKEN:-}" actor
  shift 2
  if [[ -z "$token" ]]; then token="$(greens_gh_token "$host" "$user")" || { echo "Authenticate GitHub account '${user:-active}' for $host." >&2; return 1; }; fi
  export GH_HOST="$host" GH_TOKEN="$token" GITHUB_TOKEN="$token"
  export GH_ENTERPRISE_TOKEN="$token" GITHUB_ENTERPRISE_TOKEN="$token"
  if [[ -n "$user" && "${GREENS_GH_VERIFY_ACTOR:-1}" == 1 ]]; then
    actor="$(greens_run gh api --hostname "$host" user --jq .login)" || return 1
    greens_gh_same_account "$actor" "$user" || { echo "GitHub account does not match $user on $host." >&2; return 1; }
  fi
  "$@"
)

greens_gh_api_as() {
  local host="$1" user="$2"
  shift 2
  greens_gh_as "$host" "$user" greens_run gh api --hostname "$host" "$@"
}

# Legacy setup wrote PATs in URL userinfo without a password separator. These
# documented token forms cannot be GitHub login names and remain URL credentials.
greens_is_github_url_token() {
  [[ "$1" != *:* ]] || return 1
  case "$1" in ghp_*|gho_*|ghu_*|ghs_*|ghr_*|github_pat_*) return 0 ;; esac
  [[ "$1" =~ ^[[:xdigit:]]{40}$ ]]
}

# Git's gh credential helper inherits the command-local account as well. SSH
# keeps its existing key/alias selection; other providers keep their helpers.
greens_git_transport_url() {
  local url="$1" record prefix base matched="" longest=0
  local -a options
  options=(); shift
  # Preserve command-level configuration and repository context when reading
  # insteadOf rules. --get-url expands the URL without contacting the remote.
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--config-env)
        [[ "$#" -ge 2 ]] || return 1
        options+=("$1" "$2"); shift 2 ;;
      -*) options+=("$1"); shift ;;
      *) break ;;
    esac
  done
  if [[ "${1:-}" == push ]]; then
    if git ${options[@]+"${options[@]}"} remote get-url --push "$url" 2>/dev/null; then return; fi
    # Anonymous push URLs have no remote record for get-url. Match the longest
    # pushInsteadOf prefix in Git's config order; Git expands this only once.
    while IFS= read -r -d '' record; do
      prefix="${record#*$'\n'}"; base="${record%%$'\n'*}"
      if [[ "$url" == "$prefix"* && "${#prefix}" -gt "$longest" ]]; then
        longest="${#prefix}"; base="${base#url.}"; base="${base%.pushinsteadof}"
        matched="$base${url#"$prefix"}"
      fi
    done < <(git ${options[@]+"${options[@]}"} config --null --get-regexp '^url\..*\.pushinsteadof$' 2>/dev/null)
    if [[ "$longest" -gt 0 ]]; then printf '%s\n' "$matched"; return; fi
  fi
  git ${options[@]+"${options[@]}"} ls-remote --get-url -- "$url"
}

greens_git_as() {
  local provider="$1" host="$2" user="$3" url="$4"
  shift 4
  url="$(greens_git_transport_url "$url" "$@")" || return 1
  greens_git_as_transport "$provider" "$host" "$user" "$url" "$@"
}

# The URL here has already been expanded once, just as Git expands it.
greens_git_as_transport() {
  local provider="$1" host="$2" user="$3" url="$4" token="" verify_actor=1 authority userinfo="" url_password=0 status=0
  local -a replay
  shift 4
  # A source checkout's own credential config goes first, so the account
  # overrides below still win. An explicit URL token skips it entirely.
  replay=(); [[ -z "${GREENS_SOURCE_LOGINS:-}" ]] || replay=(-c "include.path=$GREENS_SOURCE_LOGINS")
  authority="${url#*://}"; authority="${authority%%/*}"
  if [[ "$authority" == *@* ]]; then
    userinfo="${authority%@*}"
    [[ "$userinfo" != *:* ]] || url_password=1
    authority="${authority##*@}"
  fi
  if [[ "$provider" == github && "$url" == https://* ]] && greens_is_github_url_token "$userinfo"; then
    # Bind the explicit URL token for helpers too, without requiring a CLI login.
    (
      export GH_TOKEN="$userinfo" GITHUB_TOKEN="$userinfo" GH_ENTERPRISE_TOKEN="$userinfo" GITHUB_ENTERPRISE_TOKEN="$userinfo"
      greens_run git "$@"
    )
    return
  fi
  # A URL password wins; username-only URLs still need the configured actor.
  # gh's helper supports HTTPS only; leave HTTP to its existing Git helpers.
  if [[ "$provider" == github && -n "$user" && "$url" == https://* && "$url_password" == 0 ]]; then
    if [[ "${GREENS_GIT_TRANSPORT_ONLY:-0}" == 1 ]]; then
      if ! token="$(greens_gh_token "$host" "$user" 0)"; then
        GITHUB_TOKEN="${GITHUB_TOKEN:-}" greens_run git ${replay[@]+"${replay[@]}"} "$@"
        return
      fi
      # If gh has this account, a matching explicit PAT still takes priority.
      # With no saved account the native helper path above needs no API call.
      if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}" ]]; then
        token="$(greens_gh_token "$host" "$user")" || return 1
      fi
      verify_actor=0
    fi
    GREENS_COMMAND_GH_TOKEN="$token" GREENS_GH_VERIFY_ACTOR="$verify_actor" \
      greens_gh_as "$host" "$user" greens_run git ${replay[@]+"${replay[@]}"} \
      -c "credential.https://$authority.helper=" -c "credential.https://$authority.helper=!gh auth git-credential" "$@" || status=$?
    # Commits only: a gh token that can't read this repo (revoked, or an SSO org
    # it isn't authorized for) must not hide Git credentials that work. A
    # timeout (124, or 137 after the kill) would only time out again.
    [[ "$status" != 0 && "$status" != 124 && "$status" != 137 && "${GREENS_GIT_TRANSPORT_ONLY:-0}" == 1 ]] || return "$status"
    echo "The gh login for $user could not reach $authority; retrying with Git's own credentials." >&2
    GITHUB_TOKEN="${GITHUB_TOKEN:-}" greens_run git ${replay[@]+"${replay[@]}"} "$@"
  else
    GITHUB_TOKEN="${GITHUB_TOKEN:-}" greens_run git ${replay[@]+"${replay[@]}"} "$@"
  fi
}

greens_destination_git() {
  local logical_url="$1" url
  shift
  url="$(greens_git_transport_url "$logical_url" "$@")" || return 1
  greens_destination_git_transport "$logical_url" "$url" "$@"
}

greens_destination_git_transport() (
  local logical_url="$1" url="$2" authority userinfo="" token="" user identity
  shift 2
  if [[ "$url" == https://* || "$url" == http://* ]]; then
    authority="${url#*://}"; authority="${authority%%/*}"
    [[ "$authority" != *@* ]] || userinfo="${authority%@*}"
    # URL passwords need no CLI login. Other helpers may use gh: select the
    # personal actor before removing all ambient work-provider tokens.
    if [[ "$url" == https://* ]] && greens_is_github_url_token "$userinfo"; then
      token="$userinfo"
    elif [[ "$url" == https://* && "$userinfo" != *:* ]]; then
      user="${PERSONAL_GH_USER:-}"
      if [[ -z "$user" ]]; then
        identity="$(greens_remote_identity "$logical_url")" || return 1
        user="${identity#*/}"; user="${user%%/*}"
      fi
      token="$(greens_gh_token github.com "$user" 2>/dev/null)" || token=""
    fi
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
    if [[ -n "$token" ]]; then
      export GH_TOKEN="$token" GITHUB_TOKEN="$token" GH_ENTERPRISE_TOKEN="$token" GITHUB_ENTERPRISE_TOKEN="$token"
    else
      # Legacy mirrors can authenticate through GCM/keychain/store without a
      # personal gh profile. Keep those helpers after clearing work tokens.
      greens_run git "$@"
      return
    fi
  else unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; fi
  greens_git_as_transport github github.com "${PERSONAL_GH_USER:-}" "$url" "$@"
)

greens_mirror_git() {
  local logical_url url
  logical_url="$(git -C "$MIRROR_DIR" config remote.origin.url)" || return 1
  url="$(greens_git_transport_url origin -C "$MIRROR_DIR" "$@")" || return 1
  greens_destination_git_transport "$logical_url" "$url" -C "$MIRROR_DIR" "$@"
}

# Resolve destination SSH aliases for identity checks without rewriting the
# transport URL, which may select a different SSH key or port.
greens_destination_identity() {
  local url="$1" identity host resolved
  identity="$(greens_remote_identity "$url")" || return 1
  [[ "${identity#*/}" == */* ]] || return 1
  host="$(greens_remote_host "$identity")"
  identity="$host/${identity#*/}"
  if [[ "$host" != github.com && ( "$url" == ssh://* || "$url" != *://* ) ]]; then
    resolved="$(ssh -G -- "$host" 2>/dev/null | awk 'tolower($1)=="hostname" {print tolower($2); exit}' || true)"
    [[ -z "$resolved" ]] || identity="$resolved/${identity#*/}"
  fi
  [[ "$identity" == github.com/* ]] || return 1
  printf '%s\n' "$(greens_provider_identity github "$identity")"
}

# Homebrew's opt symlink survives upgrades; physical Cellar paths do not.
greens_sync_path() {
  local script="$1" prefix stable
  case "$script" in
    */Cellar/greens/*/libexec/sync.sh)
      prefix="${script%%/Cellar/greens/*}"
      stable="$prefix/opt/greens/libexec/sync.sh"
      if [[ -f "$stable" ]]; then printf '%s\n' "$stable"; return; fi
      ;;
  esac
  printf '%s\n' "$script"
}

# One Perl supervisor owns both the deadline and the child process group.
# There is no background shell/sleep retaining command-substitution pipes.
greens_perl_timeout() {
  perl -MPOSIX -MErrno=EINTR -e '
    my $seconds = shift @ARGV;
    my $pid = fork();
    defined $pid or die "fork: $!";
    if (!$pid) {
      setpgrp(0, 0) or die "setpgrp: $!";
      exec @ARGV or POSIX::_exit(127);
    }
    my $expired = 0;
    $SIG{ALRM} = sub {
      if ($expired) { kill "KILL", -$pid; }
      else { $expired = 1; kill "TERM", -$pid; alarm 10; }
    };
    alarm $seconds;
    my $waited;
    do { $waited = waitpid($pid, 0); } while ($waited == -1 && $! == EINTR);
    my $status = $?;
    alarm 0;
    if ($expired) { kill "KILL", -$pid; exit 124; }
    exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
  ' "$@"
}

greens_run() {
  local seconds="${GREENS_FETCH_TIMEOUT:-120}"
  if declare -p TIMEOUT_CMD >/dev/null 2>&1; then
    ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=10 "$seconds" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=10 "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    greens_perl_timeout "$seconds" "$@"
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

# File origins have their own host classification, distinct from network hosts.
greens_is_file_origin() {
  [[ -n "$1" ]] || return 1
  case "$1" in file://*|/*|./*|../*) return 0 ;; *://*) return 1 ;; esac
  if command -v cygpath >/dev/null 2>&1; then
    case "$1" in [a-zA-Z]:/*|[a-zA-Z]:\\*) return 0 ;; esac
  fi
  [[ "${1%%/*}" != *:* ]]
}

greens_source_url() {
  local url="$1" base="${2:-$PWD}"
  [[ -n "$url" ]] || return 1
  if greens_is_file_origin "$url" && [[ "$url" != file://* ]]; then
    case "$url" in
      /*|[a-zA-Z]:/*|[a-zA-Z]:\\*) ;;
      *)
        if command -v cygpath >/dev/null 2>&1; then
          base="$(cygpath -am "$base")" || return 1
          cygpath -am "$base/$url"
          return
        fi
        base="$(cd "$base" 2>/dev/null && pwd -P)" || return 1
        # Resolve leading dot components from the existing checkout. Leave
        # interior components intact because a remote directory may be a symlink.
        while :; do
          case "$url" in
            .) url=""; break ;; ./*) url="${url#./}" ;;
            ..) base="${base%/*}"; url=""; break ;;
            ../*) base="${base%/*}"; url="${url#../}" ;;
            *) break ;;
          esac
          [[ -n "$base" ]] || base=/
        done
        url="${base%/}${url:+/$url}"; [[ -n "$url" ]] || url=/
        ;;
    esac
  fi
  printf '%s\n' "$url"
}

greens_source_transport() {
  local url="$1" repodir="$2"
  url="$(greens_git_transport_url "$url" -C "$repodir")" || return 1
  greens_source_url "$url" "$repodir"
}

# Run on the checkout's original origin with an exact A -> B rule. Starting
# Git on the expanded B would incorrectly apply an unrelated B -> C rewrite.
greens_source_git() (
  local provider="$1" host="$2" user="$3" url="$4" repodir="$5" origin arg rule logins="" record value
  local -a args
  umask 077
  shift 5; args=()
  origin="$url"
  [[ -z "$repodir" ]] || origin="$(git -C "$repodir" config remote.origin.url)" || return 1
  # A filesystem path can also be a configured remote name (e.g. "origin").
  # Give those literal transports an unambiguous command-local URL alias.
  if greens_is_file_origin "$origin"; then origin="greens-source-$$-$RANDOM://repository"; fi
  for arg in "$@"; do
    if [[ "$arg" == "$url" ]]; then args+=("$origin"); else args+=("$arg"); fi
  done
  # A file also quotes URL keys containing '=' and keeps URL credentials out
  # of the long-running transport's command-line config arguments.
  rule="$(mktemp "${RUN_TMP:-${TMPDIR:-/tmp}}/source-transport.XXXXXX")" || return 1
  trap 'rm -f "$rule" ${logins:+"$logins"}' EXIT
  git config --file "$rule" "url.$url.insteadOf" "$origin" || return 1
  if [[ -n "$repodir" ]]; then
    # Fetches run on the bare cache, which can't see the checkout's own
    # credential config (repo-local, or a global includeIf "gitdir:"). Replay
    # the checkout's helper list, starting from a reset.
    logins="$(mktemp "${RUN_TMP:-${TMPDIR:-/tmp}}/source-logins.XXXXXX")" || return 1
    git config --file "$logins" credential.helper "" || return 1
    while IFS= read -r -d '' record; do
      value=true; [[ "$record" != *$'\n'* ]] || value="${record#*$'\n'}"
      git config --file "$logins" --add "${record%%$'\n'*}" "$value" || return 1
    done < <(git -C "$repodir" config --null --get-regexp '^credential\.' 2>/dev/null)
  fi
  GREENS_SOURCE_LOGINS="$logins" greens_git_as_transport "$provider" "$host" "$user" "$url" -c "include.path=$rule" ${args[@]+"${args[@]}"}
)

greens_uri_path_encode() (
  export LC_ALL=C
  local value="$1" encoded="" char hex byte
  while [[ -n "$value" ]]; do
    char="${value:0:1}"; value="${value:1}"
    case "$char" in
      [a-zA-Z0-9._~/:\-]) encoded+="$char" ;;
      *)
        printf -v byte '%d' "'$char"
        printf -v hex '%02X' "$((byte & 255))"
        encoded+="%$hex"
        ;;
    esac
  done
  printf '%s' "$encoded"
)

greens_uri_path_decode() {
  local value="$1" decoded="" prefix tail hex char
  while [[ "$value" == *%[[:xdigit:]][[:xdigit:]]* ]]; do
    prefix="${value%%%[[:xdigit:]][[:xdigit:]]*}"
    tail="${value#"$prefix"}"; hex="${tail:1:2}"
    # Reject field separators before command substitution can trim a newline.
    case "$hex" in 00|09|0[aA]) return 1 ;; esac
    printf -v char '%b' "\\x$hex"
    decoded+="$prefix$char"; value="${tail:3}"
  done
  printf '%s' "$decoded$value"
}

greens_file_identity() {
  local url="$1" base="${2:-$PWD}" authority="" path body
  if [[ "$url" == file://* ]]; then
    body="${url#file://}"; [[ "$body" == */* ]] || return 1
    authority="${body%%/*}"; authority="${authority##*@}"
    path="/$(greens_uri_path_decode "${body#*/}")" || return 1
  else path="$(greens_source_url "$url" "$base")" || return 1; fi
  [[ "$path" != *$'\t'* && "$path" != *$'\n'* ]] || return 1
  authority="$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$authority" || "$authority" == localhost ]]; then
    authority=""
    if [[ "$url" != file://* ]] && command -v cygpath >/dev/null 2>&1; then
      path="$(cygpath -am "$path")" || return 1
      if [[ "$path" == //* ]]; then
        body="${path#//}"; authority="${body%%/*}"; path="/${body#*/}"
      else [[ "$path" == /* ]] || path="/$path"; fi
    fi
  fi
  case "$path" in /|/[a-zA-Z]:/) ;; *) path="${path%/}" ;; esac
  authority="$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')"
  printf 'file://%s%s\n' "$authority" "$(greens_uri_path_encode "$path")"
}

# The default projects a host/path for compatibility. Collection passes 1 to
# retain a sanitized transport endpoint; only known providers canonicalize it.
greens_remote_identity() {
  local url="$1" preserve_transport="${2:-0}" authority path login="" scheme="${1%%://*}"
  [[ -n "$url" ]] || return 1
  if greens_is_file_origin "$url"; then greens_file_identity "$url" "${3:-$PWD}"; return; fi
  case "$url" in
    *://*)
      url="${url#*://}"
      [[ "$url" == */* ]] || return 1
      authority="${url%%/*}"; path="${url#*/}"
      case "$scheme" in git+ssh|ssh+git) scheme=ssh ;; esac
      if [[ "$preserve_transport" == 1 && "$scheme" == ssh && "$authority" == *@* ]]; then
        login="${authority%@*}"; [[ "$login" != *:* ]] || return 1
      fi
      authority="${authority##*@}"
      ;;
    *:*)
      authority="${url%%]:*}"
      if [[ "$url" == *']:'* && "${authority##*@}" == \[* && "$authority" != */* ]]; then
        authority+=']'; path="${url#*]:}"
      else authority="${url%%:*}"; path="${url#*:}"; fi
      scheme=ssh
      [[ -n "$path" ]] || return 1
      if [[ "$preserve_transport" == 1 ]]; then
        [[ "$authority" != *@* ]] || login="${authority%@*}"
        # The tilde marks the remote SSH home, never this machine's HOME.
        # shellcheck disable=SC2088
        case "$path" in /*) path="${path#/}" ;; '~'*) ;; *) path="~/$path" ;; esac
      fi
      authority="${authority##*@}"
      ;;
    *) return 1 ;;
  esac
  path="${path%/}"
  if [[ "$preserve_transport" != 1 ]]; then path="${path#/}"; path="${path%.git}"; fi
  [[ -n "$authority" && -n "$path" && "$path" != *$'\t'* && "$path" != *$'\n'* ]] || return 1
  authority="$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')"
  if [[ "$preserve_transport" == 1 ]]; then
    printf '%s://%s%s/%s\n' "$scheme" "${login:+$login@}" "$authority" "$path"
  else printf '%s/%s\n' "$authority" "$path"; fi
}

# Project grouping is independent of generic endpoint/SSH path semantics.
greens_remote_path() {
  local identity="$1" path
  identity="${identity#*://}"
  path="${identity#*/}"; path="${path#/}"
  [[ "$1" != ssh://* ]] || path="${path#\~/}"
  printf '%s\n' "${path%.git}"
}

greens_remote_host() {
  local authority="${1#*://}"
  authority="${authority%%/*}"; authority="${authority##*@}"
  if [[ "$1" == file://* ]]; then printf 'file://%s\n' "${authority:-localhost}"; return; fi
  case "$authority" in
    \[*\]*) printf '%s]\n' "${authority%%]*}" ;;
    *) printf '%s\n' "${authority%%:*}" ;;
  esac
}

# Filesystem hierarchy is an identity detail, not a published repository name.
greens_project_display_name() {
  local path
  path="$(greens_remote_path "$1")" || return 1
  if [[ "$1" == file://* ]]; then greens_uri_path_decode "${path##*/}"
  else printf '%s\n' "$path"; fi
}

# Configuration locks protect this namespace, including bare-repo init/fetch.
# Different configs may intentionally share CACHE_DIR and use different actors.
greens_bare_cache_dir() {
  printf '%s/bare/%s\n' "$CACHE_DIR" "$(greens_scheduler_id)"
}

greens_seed_bare_cache() {
  local target="$1" old="$2" tmp
  [[ ! -e "$target" && -d "$old" && ! -L "$old" ]] || return 0
  [[ "$(git --git-dir="$old" rev-parse --is-bare-repository 2>/dev/null)" == true ]] || return 0
  # Preserve independent storage and avoid external object dependencies.
  [[ ! -f "$old/objects/info/alternates" ]] || return 0
  mkdir -p "$(dirname "$target")"
  tmp="$(mktemp -d "$target.seed.XXXXXX")" || return 1
  if ! git clone --mirror --local --no-hardlinks --quiet "$old" "$tmp"; then rm -rf "$tmp"; return 0; fi
  # Keep only the newly generated core config; source credentials/helpers and
  # the temporary local origin must not become this configuration's transport.
  git --git-dir="$tmp" config --remove-section remote.origin || { rm -rf "$tmp"; return 1; }
  mv "$tmp" "$target"
}

greens_scheduler_id() {
  local hash
  hash="$(printf '%s' "$CONFIG_FILE" | greens_hash)"
  printf 'greens-%s' "${hash:0:12}"
}

greens_scheduler_platform() {
  local system
  system="$(uname -s)"
  if [[ "$system" == MINGW* || "$system" == MSYS* || -n "${WINDIR:-}" ]]; then
    printf 'windows\n'
  elif [[ "$system" == Darwin ]]; then
    printf 'macos\n'
  elif [[ "$system" == Linux ]]; then
    printf 'linux\n'
  else
    printf 'other\n'
  fi
}

greens_launchd_label() {
  printf 'com.greens.%s\n' "$(greens_scheduler_id)"
}

greens_remove_launchd() {
  local label plist
  label="$(greens_launchd_label)"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  command -v launchctl >/dev/null && launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$plist"
}

greens_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

greens_install_launchd() {
  local script="$1" hour="$2" label plist log_dir label_xml script_xml log_dir_xml config_xml path_xml
  script="$(greens_sync_path "$script")"
  command -v launchctl >/dev/null || { echo "launchctl is unavailable; choose cron or manual." >&2; return 1; }
  label="$(greens_launchd_label)"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  log_dir="${LOG_DIR:-$(dirname "$CONFIG_FILE")/logs}"
  mkdir -p "$(dirname "$plist")" "$log_dir"
  label_xml="$(greens_xml_escape "$label")"
  script_xml="$(greens_xml_escape "$script")"
  log_dir_xml="$(greens_xml_escape "$log_dir")"
  config_xml="$(greens_xml_escape "$CONFIG_FILE")"
  path_xml="$(greens_xml_escape "$PATH")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label_xml</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$script_xml</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>0</integer></dict>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$log_dir_xml/sync.out.log</string>
<key>StandardErrorPath</key><string>$log_dir_xml/sync.err.log</string>
<key>EnvironmentVariables</key><dict><key>CONTRIB_MIRROR_CONFIG</key><string>$config_xml</string><key>PATH</key><string>$path_xml</string><key>GREENS_SYNC_HOUR</key><string>$hour</string></dict>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
}

greens_remove_windows_task() {
  command -v schtasks.exe >/dev/null || return 0
  MSYS_NO_PATHCONV=1 schtasks.exe /Delete /TN greens-daily-sync /F 2>/dev/null || true
}

greens_install_windows_task() {
  local script="$1" hour="$2" gitbash="" path win_bash mixed_sync log_dir mixed_log task_time win_user
  script="$(greens_sync_path "$script")"
  command -v schtasks.exe >/dev/null || { echo "Windows Task Scheduler is unavailable; choose manual." >&2; return 1; }
  for path in "/c/Program Files/Git/bin/bash.exe" "/c/Program Files (x86)/Git/bin/bash.exe" "${LOCALAPPDATA:-}/Programs/Git/bin/bash.exe"; do
    if [[ -f "$path" ]]; then gitbash="$path"; break; fi
  done
  gitbash="${gitbash:-$(command -v bash 2>/dev/null || true)}"
  [[ -n "$gitbash" ]] || { echo "Git Bash is unavailable; choose manual." >&2; return 1; }
  win_bash="$(cygpath -w "$gitbash" 2>/dev/null || printf '%s' "$gitbash")"
  mixed_sync="$(cygpath -m "$script" 2>/dev/null || printf '%s' "$script" | sed 's|\\|/|g')"
  log_dir="${LOG_DIR:-$(dirname "$CONFIG_FILE")/logs}"
  mkdir -p "$log_dir"
  mixed_log="$(cygpath -m "$log_dir/sync.log" 2>/dev/null || printf '%s' "$log_dir/sync.log")"
  task_time="$(printf '%02d:00' "$hour")"
  win_user="$(cmd.exe /C "echo %USERNAME%" 2>/dev/null | tr -d '\r')"
  greens_remove_windows_task
  MSYS_NO_PATHCONV=1 schtasks.exe /Create /TN greens-daily-sync \
    /TR "\"$win_bash\" --login -c \"CONTRIB_MIRROR_CONFIG='$CONFIG_FILE' bash '$mixed_sync' >> '$mixed_log' 2>&1\"" \
    /SC DAILY /ST "$task_time" /RU "$win_user" /RL LIMITED /F
}

greens_remove_all_schedulers() {
  local keep="${2:-}" timer
  timer="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$(greens_scheduler_id).timer"
  [[ "$keep" == systemd || ! -f "$timer" ]] || greens_systemd_remove
  [[ "$keep" == cron ]] || greens_remove_cron
  [[ "$keep" == launchd ]] || greens_remove_launchd
  [[ "$keep" == win ]] || greens_remove_windows_task
  greens_remove_legacy_schedulers
}

greens_validate_scheduler() {
  case "$1" in
    systemd)
      if ! command -v systemctl >/dev/null || ! systemctl --user show-environment >/dev/null 2>&1; then
        echo "systemd user manager is unavailable; choose cron or manual." >&2
        return 1
      fi ;;
    cron) command -v crontab >/dev/null || { echo "crontab is unavailable; choose manual." >&2; return 1; } ;;
    launchd) command -v launchctl >/dev/null || { echo "launchctl is unavailable; choose cron or manual." >&2; return 1; } ;;
    win) command -v schtasks.exe >/dev/null || { echo "Windows Task Scheduler is unavailable; choose manual." >&2; return 1; } ;;
    manual) ;;
    *) return 1 ;;
  esac
}

# v1.8.2 jobs have no configuration selector, so they belong to the default
# config. Retire them when replacing that config's schedule, including manual.
greens_remove_legacy_schedulers() {
  local tmp legacy_tail
  [[ "$CONFIG_FILE" == "$(greens_config_path "$HOME/.contrib-mirror/config")" ]] || return 0
  command -v launchctl >/dev/null && launchctl bootout "gui/$(id -u)/com.greens" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.greens.plist"
  command -v crontab >/dev/null || return 0
  tmp="$(mktemp)" || return 1
  legacy_tail=" >> $HOME/.contrib-mirror/logs/sync.log 2>&1"
  if crontab -l > "$tmp" 2>/dev/null; then
    awk -v tail="$legacy_tail" '
      {
        command=$0
        sub(/^[[:space:]]*0[[:space:]]+[0-9]+[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+/, "", command)
        path=substr(command,1,length(command)-length(tail))
        if (command != $0 && path ~ /^\/bin\/bash .*\/sync[.]sh$/ && substr(command,length(path)+1)==tail) next
        print
      }' "$tmp" > "$tmp.next"
    if ! cmp -s "$tmp" "$tmp.next"; then
      crontab - < "$tmp.next" || { rm -f "$tmp" "$tmp.next"; return 1; }
    fi
  fi
  rm -f "$tmp" "$tmp.next"
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
  script="$(greens_sync_path "$script")"
  greens_validate_scheduler systemd || return 1
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
  script="$(greens_sync_path "$script")"
  id="$(greens_scheduler_id)"
  printf -v line '0 %s * * * PATH=%q CONTRIB_MIRROR_CONFIG=%q /bin/bash %q >> %q 2>&1 # %s' \
    "$hour" "$PATH" "$CONFIG_FILE" "$script" "${LOG_DIR:-$HOME/.contrib-mirror/logs}/sync.log" "$id"
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
