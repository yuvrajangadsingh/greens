#!/bin/bash
# Account isolation with real Git credential helpers and fixture GitHub APIs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT_TEST="$(mktemp -d)"
ACCOUNT_TEST="$(cd "$ACCOUNT_TEST" && pwd -P)"
trap 'rm -rf "$ACCOUNT_TEST"' EXIT
export ACCOUNT_TEST HOME="$ACCOUNT_TEST/home" GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$ACCOUNT_TEST/gitconfig"
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
export GH_HOST=github.com
mkdir -p "$HOME" "$ACCOUNT_TEST/bin" "$ACCOUNT_TEST/ready"
export PATH="$ACCOUNT_TEST/bin:$PATH"
ln -s "$BASH" "$ACCOUNT_TEST/bin/bash"
# Reproduce macOS without coreutils through the actual production selector,
# including child sync processes. Do not replace the timeout implementation.
if [[ "${GREENS_TEST_PERL_TIMEOUT:-0}" == 1 ]]; then
  mkdir -p "$ACCOUNT_TEST/perl-path"
  while IFS= read -r directory; do
    [[ -d "$directory" ]] || continue
    for executable in "$directory/"*; do
      name="${executable##*/}"
      [[ "$name" != timeout && "$name" != gtimeout && -f "$executable" && -x "$executable" ]] || continue
      [[ -e "$ACCOUNT_TEST/perl-path/$name" || -L "$ACCOUNT_TEST/perl-path/$name" ]] || ln -s "$executable" "$ACCOUNT_TEST/perl-path/$name"
    done
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  export PATH="$ACCOUNT_TEST/bin:$ACCOUNT_TEST/perl-path"
fi
source "$ROOT/lib/common.sh"
source "$ROOT/lib/gitlab.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$ACCOUNT_TEST/bin/gh" <<'MOCK'
#!/bin/bash
set -eu
case "$*" in
  'auth switch '*) touch "$ACCOUNT_TEST/switched"; exit 99 ;;
  'auth status '*' --json hosts --jq '*) [[ ! -f "$ACCOUNT_TEST/no-json-status" ]] || exit 1; printf 'alice\nbob\ncarol\n' ;;
  'auth status'*) [[ ! -f "$ACCOUNT_TEST/no-json-status" ]] || echo 'Logged in to github.com account alice (keyring)'; exit 1 ;; # Active account expired.
  'auth token --hostname '*' --user '*)
    user="${*: -1}"
    case "$user" in alice|bob|carol) printf 'fixture-%s\n' "$user" ;; *) exit 1 ;; esac ;;
  'auth token --hostname '*) [[ -f "$ACCOUNT_TEST/setup-active" ]] || exit 1; echo fixture-bob ;;
  'auth git-credential get')
    cat >/dev/null
    printf 'username=%s\npassword=%s\n' "${GH_TOKEN#fixture-}" "$GH_TOKEN" ;;
  'api --hostname '*' user --jq .login')
    case "${GH_TOKEN:-}" in fixture-alice-sso) echo alice ;; fixture-alice|fixture-bob|fixture-pat|fixture-carol) echo "${GH_TOKEN#fixture-}" ;; *) exit 1 ;; esac ;;
  'api --hostname github.com user') printf '{"login":"%s"}\n' "${GH_TOKEN#fixture-}" ;;
  'api --hostname github.com user/emails --jq '*) echo mirror@example.test ;;
  'api --hostname github.com repos/bob/'*) echo '{"private":true,"default_branch":"main"}' ;;
  'api --hostname '*' users/team --jq .type') echo Organization ;;
  'api --hostname '*' users/otherteam --jq .type') echo Organization ;;
  'api --hostname '*' --paginate -X GET search/issues'*)
    printf '%s\n' "$*" >> "$ACCOUNT_TEST/github-queries"
    if [[ "$*" == *org:otherteam* ]]; then
      echo '{"items":[{"id":99,"created_at":"2021-01-02T12:00:00Z","repository_url":"https://api.github.com/repos/otherteam/repo"}]}'
    else echo '{"items":[]}'; fi ;;
  'search issues --author=alice '*|'search issues --author=ALICE '*) [[ "$GH_TOKEN" == fixture-alice ]] || exit 1; echo '2021-01-02T12:00:00Z' ;;
  'repo view '*) echo PUBLIC ;;
  'api --hostname '*' probe/'*)
    actor="${4#probe/}"
    [[ "$GH_TOKEN" == "fixture-$actor" ]] || exit 1
    touch "$ACCOUNT_TEST/ready/$actor"
    for ((i=0;i<100;i++)); do
      if [[ -e "$ACCOUNT_TEST/ready/alice" && -e "$ACCOUNT_TEST/ready/bob" ]]; then echo "$actor"; exit 0; fi
      sleep 0.05
    done
    exit 1 ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$ACCOUNT_TEST/bin/gh"

# Both requests must overlap, each uses its own token, neither can switch the
# shared account, and an expired active session does not block named accounts.
greens_gh_api_as github.com alice probe/alice > "$ACCOUNT_TEST/alice" & alice_pid=$!
greens_gh_api_as github.com bob probe/bob > "$ACCOUNT_TEST/bob" & bob_pid=$!
wait "$alice_pid" || fail "Alice's concurrent request"
wait "$bob_pid" || fail "Bob's concurrent request"
[[ "$(cat "$ACCOUNT_TEST/alice")" == alice && "$(cat "$ACCOUNT_TEST/bob")" == bob ]] || fail "request actor changed"
[[ -z "${GH_TOKEN:-}" && -z "${GH_ENTERPRISE_TOKEN:-}" ]] || fail "command credentials escaped into parent"

git config --global user.name Fixture
git config --global user.email author@example.test
git config --global commit.gpgsign false
git init --quiet "$ACCOUNT_TEST/source"
git -C "$ACCOUNT_TEST/source" symbolic-ref HEAD refs/heads/main
GIT_AUTHOR_DATE=2021-01-01T12:00:00Z GIT_COMMITTER_DATE=2021-01-01T12:00:00Z \
  git -C "$ACCOUNT_TEST/source" commit --quiet --allow-empty -m private
git clone --bare --quiet "$ACCOUNT_TEST/source" "$ACCOUNT_TEST/source.git"
git -C "$ACCOUNT_TEST/source" remote add origin https://github.com/team/repo
git config --global url."$ACCOUNT_TEST/source.git".insteadOf https://github.com/team/repo
git init --bare --quiet "$ACCOUNT_TEST/mirror.git"
git init --quiet "$ACCOUNT_TEST/mirror"
git -C "$ACCOUNT_TEST/mirror" symbolic-ref HEAD refs/heads/main
git -C "$ACCOUNT_TEST/mirror" remote add origin https://github.com/bob/mirror
git config --global url."$ACCOUNT_TEST/mirror.git".insteadOf https://github.com/bob/mirror

# An unrelated configured helper would return the personal account. The
# source command must override it using Alice's command-local gh credentials.
git config --global credential.https://github.com.helper '!printf "username=bob\npassword=wrong\n"'
printf 'protocol=https\nhost=github.com\n\n' |
  greens_git_as github github.com alice https://github.com/team/repo credential fill > "$ACCOUNT_TEST/source-credentials"
grep -qx username=alice "$ACCOUNT_TEST/source-credentials" || fail "source inherited personal Git credentials"
printf 'protocol=https\nhost=github.com\nusername=alice\n\n' |
  GH_TOKEN=fixture-bob GITHUB_TOKEN=fixture-bob greens_git_as github github.com alice https://alice@github.com/team/repo credential fill > "$ACCOUNT_TEST/source-username-credentials"
grep -qx password=fixture-alice "$ACCOUNT_TEST/source-username-credentials" || fail "username-only source inherited another account's token"
MIRROR_DIR="$ACCOUNT_TEST/mirror" PERSONAL_GH_USER=bob
printf 'protocol=https\nhost=github.com\n\n' |
  greens_mirror_git credential fill > "$ACCOUNT_TEST/mirror-credentials"
grep -qx username=bob "$ACCOUNT_TEST/mirror-credentials" || fail "destination inherited source Git credentials"

# A clone host can differ from the API host, including its port. HTTP keeps
# its existing helper because gh auth git-credential only supports HTTPS.
printf 'protocol=https\nhost=clone.example:8443\n\n' |
  greens_git_as github api.example ALICE https://clone.example:8443/team/repo credential fill > "$ACCOUNT_TEST/clone-credentials"
grep -qx username=alice "$ACCOUNT_TEST/clone-credentials" || fail "credential helper was bound to API host"
git config --global credential.http://clone.example.helper '!printf "username=http-user\npassword=fixture-http\n"'
printf 'protocol=http\nhost=clone.example\n\n' |
  greens_git_as github api.example alice http://clone.example/team/repo credential fill > "$ACCOUNT_TEST/http-credentials"
grep -qx username=http-user "$ACCOUNT_TEST/http-credentials" || fail "HTTP helper was replaced by gh"
[[ "$(greens_gh_api_as github.com ALICE user --jq .login)" == alice ]] || fail "case-sensitive stored account lookup"
touch "$ACCOUNT_TEST/no-json-status"
[[ "$(greens_gh_api_as github.com ALICE user --jq .login)" == alice ]] || fail "older gh account spelling lookup"
rm "$ACCOUNT_TEST/no-json-status"
[[ "$(GITHUB_TOKEN=fixture-alice-sso greens_gh_token github.com ALICE)" == fixture-alice-sso ]] || fail "saved token replaced explicit scoped PAT"
[[ "$(GITHUB_TOKEN=fixture-alice-sso greens_gh_api_as github.com ALICE user --jq .login)" == alice ]] || fail "PAT actor comparison was case-sensitive"
printf 'protocol=https\nhost=github.com\n\n' |
  GITHUB_TOKEN=fixture-alice-sso GREENS_GIT_TRANSPORT_ONLY=1 greens_git_as github github.com ALICE https://github.com/team/repo credential fill > "$ACCOUNT_TEST/scoped-credentials"
grep -qx password=fixture-alice-sso "$ACCOUNT_TEST/scoped-credentials" || fail "commit-only transport ignored matching explicit PAT"
[[ "$(GH_TOKEN=fixture-alice greens_gh_token github.com bob)" == fixture-bob ]] || fail "work PAT replaced personal credentials"
# v1.8.2 can save a personal PAT directly in the mirror URL while only the
# work account is logged into gh. This must work outside transport-only mode.
git -C "$MIRROR_DIR" remote set-url origin https://url-user:fixture-personal@github.com/bob/mirror
PERSONAL_GH_USER=not-logged-in
printf 'protocol=https\nhost=github.com\nusername=url-user\npassword=fixture-personal\n\n' |
  GH_TOKEN=fixture-alice greens_mirror_git credential fill > "$ACCOUNT_TEST/pat-mirror-credentials"
grep -qx password=fixture-personal "$ACCOUNT_TEST/pat-mirror-credentials" || fail "mirror URL credentials required personal gh login"
git -C "$MIRROR_DIR" remote set-url origin https://github.com/bob/mirror
PERSONAL_GH_USER=bob
# A username-only personal URL still asks a credential helper for a password.
# Ambient work tokens must never become that password, even in commits-only runs.
git config --global credential.https://github.com.helper '!gh auth git-credential'
# The old wizard used token-only userinfo, not username:password. No personal
# CLI profile may be required, and a helper must receive that explicit token.
for url_token in ghp_fixture_personal_token 0123456789abcdef0123456789abcdef01234567; do
  PERSONAL_GH_USER=not-logged-in
  git -C "$MIRROR_DIR" remote set-url origin "https://$url_token@github.com/bob/mirror"
  printf 'protocol=https\nhost=github.com\nusername=%s\n\n' "$url_token" |
    GH_TOKEN=fixture-alice GITHUB_TOKEN=fixture-alice greens_mirror_git credential fill > "$ACCOUNT_TEST/token-only-url-credentials"
  grep -qx "password=$url_token" "$ACCOUNT_TEST/token-only-url-credentials" || fail "legacy token-only URL required a personal CLI login or inherited the work token"
  printf 'protocol=https\nhost=github.com\nusername=%s\n\n' "$url_token" |
    GH_TOKEN=fixture-bob greens_git_as github github.com alice "https://$url_token@github.com/team/repo" credential fill > "$ACCOUNT_TEST/source-token-url-credentials"
  grep -qx "password=$url_token" "$ACCOUNT_TEST/source-token-url-credentials" || fail "source URL token was replaced by ambient credentials"
done
PERSONAL_GH_USER=bob
git -C "$MIRROR_DIR" remote set-url origin https://bob@github.com/bob/mirror
printf 'protocol=https\nhost=github.com\nusername=bob\n\n' |
  GH_TOKEN=fixture-alice GITHUB_TOKEN=fixture-alice GH_ENTERPRISE_TOKEN=fixture-alice GITHUB_ENTERPRISE_TOKEN=fixture-alice \
  greens_mirror_git credential fill > "$ACCOUNT_TEST/username-mirror-credentials"
grep -qx password=fixture-bob "$ACCOUNT_TEST/username-mirror-credentials" || fail "destination helper inherited a work PAT"
printf 'protocol=https\nhost=github.com\nusername=bob\n\n' |
  GH_TOKEN=fixture-alice GITHUB_TOKEN=fixture-alice greens_destination_git https://bob@github.com/bob/mirror credential fill > "$ACCOUNT_TEST/initial-clone-credentials"
grep -qx password=fixture-bob "$ACCOUNT_TEST/initial-clone-credentials" || fail "initial destination credentials inherited the work actor"
git -C "$MIRROR_DIR" remote set-url origin https://github.com/bob/mirror

# Exercise the complete indexed collector while gh auth status fails. The Git
# transports are local bare repositories, with the original HTTPS identities.
# Config values are read dynamically by the collector.
# shellcheck disable=SC2034
SOURCE_COUNT=1 SOURCE_1_PROVIDER=github SOURCE_1_API_HOST=github.com SOURCE_1_REMOTE_HOSTS=github.com \
SOURCE_1_ORGANIZATION=team SOURCE_1_USERNAME=ALICE SOURCE_1_EMAILS=author@example.test \
SOURCE_1_SINCE=2021-01-01 SOURCE_1_ACTIVITY_TYPES=commits,issues SOURCE_1_ACCESS_MODE=remote
WORK_DIRS="$ACCOUNT_TEST/source" CACHE_DIR="$ACCOUNT_TEST/cache" RUN_TMP="$ACCOUNT_TEST/run"
CONFIG_FILE="$ACCOUNT_TEST/config" SUCCESS_STAMP_FILE="$ACCOUNT_TEST/stamp" MIRROR_EMAIL=mirror@example.test MIRROR_NAME=greens
mkdir -p "$RUN_TMP" "$CACHE_DIR"
log() { printf '%s\n' "$*"; }
mirror_visibility() { echo public; }
greens_offer_local_fallback() { fail "valid configured source was offered local fallback"; }
greens_mixed_sync > "$ACCOUNT_TEST/sync-output" 2>&1 || { cat "$ACCOUNT_TEST/sync-output"; fail "named account sync with expired active account"; }
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 1 ]] || fail "source commits were omitted"
[[ ! -e "$ACCOUNT_TEST/switched" ]] || fail "changed the shared gh account"

# Two configurations may share CACHE_DIR while fetching the same repository.
# Hold both initializations at remote-add so a shared bare path fails reliably.
(
  CACHE_DIR="$ACCOUNT_TEST/shared-cache"
  mkdir -p "$ACCOUNT_TEST/race-ready"
  for label in one two; do
    git init --bare --quiet "$ACCOUNT_TEST/race-$label.git"
    git init --quiet "$ACCOUNT_TEST/race-$label"
    git -C "$ACCOUNT_TEST/race-$label" symbolic-ref HEAD refs/heads/main
    git -C "$ACCOUNT_TEST/race-$label" remote add origin "$ACCOUNT_TEST/race-$label.git"
  done
  export ACCOUNT_REAL_GIT
  ACCOUNT_REAL_GIT="$(command -v git)"
  mkdir -p "$ACCOUNT_TEST/race-bin"
  cat > "$ACCOUNT_TEST/race-bin/git" <<'MOCK'
#!/bin/bash
set -eu
if [[ "${1:-}" == --git-dir=* && "${2:-}" == remote && "${3:-}" == add ]]; then
  printf '%s\n' "${1#--git-dir=}" > "$ACCOUNT_TEST/race-ready/$GREENS_RACE_LABEL"
  for ((attempt=0;attempt<100;attempt++)); do
    [[ "$(find "$ACCOUNT_TEST/race-ready" -type f | wc -l | tr -d ' ')" == 2 ]] && break
    sleep 0.05
  done
  [[ "$attempt" -lt 100 ]] || exit 1
fi
exec "$ACCOUNT_REAL_GIT" "$@"
MOCK
  chmod +x "$ACCOUNT_TEST/race-bin/git"
  export PATH="$ACCOUNT_TEST/race-bin:$PATH"
  for label in one two; do
    (
      export GREENS_RACE_LABEL="$label"
      CONFIG_FILE="$ACCOUNT_TEST/race-$label-config" RUN_TMP="$ACCOUNT_TEST/race-$label-run"
      MIRROR_DIR="$ACCOUNT_TEST/race-$label" SUCCESS_STAMP_FILE="$ACCOUNT_TEST/race-$label-stamp"
      mkdir -p "$RUN_TMP" "$CACHE_DIR"
      greens_mixed_sync > "$ACCOUNT_TEST/race-$label-output" 2>&1
    ) &
    if [[ "$label" == one ]]; then first_pid=$!; else second_pid=$!; fi
  done
  wait "$first_pid" || { cat "$ACCOUNT_TEST/race-one-output"; fail "first concurrent configuration"; }
  wait "$second_pid" || { cat "$ACCOUNT_TEST/race-two-output"; fail "second concurrent configuration"; }
  [[ "$(cat "$ACCOUNT_TEST/race-ready/"* | sort -u | wc -l | tr -d ' ')" == 2 ]] || fail "configs shared a bare repository"
  for label in one two; do
    [[ "$(command git -C "$ACCOUNT_TEST/race-$label" rev-list --count HEAD)" == 1 ]] || fail "concurrent configuration lost activity"
  done
) || fail "concurrent cache regression"

# Environment-only PATs still work, but may not impersonate a different actor.
[[ "$(GH_TOKEN=fixture-pat greens_gh_api_as github.com pat user --jq .login)" == pat ]] || fail "PAT-only account"
[[ "$(GH_ENTERPRISE_TOKEN=fixture-bob greens_gh_api_as github.example alice user --jq .login)" == alice ]] || fail "Enterprise named account isolation"
if GH_TOKEN=fixture-bob greens_gh_api_as github.com missing user --jq .login > /dev/null 2>&1; then fail "accepted mismatched PAT actor"; fi

# A saved username does not require gh for transport-only access. Even an
# unrelated ambient PAT must leave a working non-gh credential helper intact.
git config --global credential.https://github.com.helper '!printf "username=external\npassword=fixture-vault\n"'
printf 'protocol=https\nhost=github.com\n\n' |
  GH_TOKEN=fixture-bob GREENS_GIT_TRANSPORT_ONLY=1 greens_git_as github github.com external https://github.com/team/repo credential fill > "$ACCOUNT_TEST/external-credentials"
grep -qx username=external "$ACCOUNT_TEST/external-credentials" || fail "commit-only access replaced a non-gh credential helper"
printf 'protocol=https\nhost=github.com\nusername=url-user\npassword=fixture-url\n\n' |
  GREENS_GIT_TRANSPORT_ONLY=1 greens_git_as github github.com alice https://url-user:fixture-url@github.com/team/repo credential fill > "$ACCOUNT_TEST/url-credentials"
grep -qx username=url-user "$ACCOUNT_TEST/url-credentials" || fail "commit-only access replaced URL credentials"
(
  # Config values are read dynamically by greens_mixed_sync.
  # shellcheck disable=SC2034
  SOURCE_1_USERNAME=external SOURCE_1_ACTIVITY_TYPES=commits
  RUN_TMP="$ACCOUNT_TEST/transport-run"
  mkdir -p "$RUN_TMP"
  greens_mixed_sync > "$ACCOUNT_TEST/transport-output" 2>&1 || { cat "$ACCOUNT_TEST/transport-output"; fail "transport-only sync required a gh login"; }
)

# Existing v1.8.2-style configurations use the same isolated accounts for API
# collection and mirror access, even when the active account has expired.
(
  CONFIG_FILE="$ACCOUNT_TEST/legacy-config"
  MIRROR_DIR="$ACCOUNT_TEST/legacy-mirror" CACHE_DIR="$ACCOUNT_TEST/legacy-cache" LOG_DIR="$ACCOUNT_TEST/legacy-logs"
  git init --bare --quiet "$ACCOUNT_TEST/legacy-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin https://github.com/bob/legacy-mirror
  git config --global url."$ACCOUNT_TEST/legacy-mirror.git".insteadOf https://github.com/bob/legacy-mirror
  # Config values are consumed by name in greens_save_config.
  # shellcheck disable=SC2034
  WORK_DIR="$ACCOUNT_TEST/source" REMOTE_PREFIX="$ACCOUNT_TEST/" GITHUB_USERNAME=ALICE GITHUB_ORG=team \
    ACTIVITY_TYPES=commits,issues EMAILS=author@example.test SINCE='2021-01-01 00:00:00'
  greens_save_config "$CONFIG_FILE" WORK_DIR REMOTE_PREFIX GITHUB_USERNAME GITHUB_ORG ACTIVITY_TYPES EMAILS SINCE \
    MIRROR_DIR CACHE_DIR LOG_DIR MIRROR_EMAIL PERSONAL_GH_USER
  mkdir -p "$CACHE_DIR"
  git clone --bare --quiet "$ACCOUNT_TEST/source.git" "$CACHE_DIR/source.git"
  FORCE=1 CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/sync.sh" > "$ACCOUNT_TEST/legacy-output" 2>&1 || {
    cat "$ACCOUNT_TEST/legacy-output"; fail "legacy account isolation";
  }
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 2 ]] || fail "legacy source API activity was skipped"
  if grep -q 'Cloning source.git' "$ACCOUNT_TEST/legacy-output"; then fail "upgrade did not reuse its existing bare cache"; fi
  [[ -d "$CACHE_DIR/bare/$(greens_scheduler_id)/source.git" ]] || fail "upgrade cache was not namespaced"
)
[[ ! -e "$ACCOUNT_TEST/switched" ]] || fail "legacy sync changed the shared account"

# Migrate a PAT that exists only as a non-exported config assignment. Both the
# wizard's initial subprocess and a fresh scheduled-style process need it.
(
  CONFIG_FILE="$ACCOUNT_TEST/pat-config"
  MIRROR_DIR="$ACCOUNT_TEST/pat-mirror" CACHE_DIR="$ACCOUNT_TEST/pat-cache" LOG_DIR="$ACCOUNT_TEST/pat-logs"
  git init --bare --quiet "$ACCOUNT_TEST/pat-mirror.git"
  git --git-dir="$ACCOUNT_TEST/pat-mirror.git" symbolic-ref HEAD refs/heads/main
  git config --global url."$ACCOUNT_TEST/pat-mirror.git".insteadOf https://github.com/bob/pat-mirror
  # Passed by variable name to greens_save_config.
  # shellcheck disable=SC2034
  SOURCE_PROVIDER=github WORK_DIR="$ACCOUNT_TEST/source" REMOTE_PREFIX=https://github.com/team/ \
    GITHUB_USERNAME=pat GITHUB_TOKEN=fixture-pat ACTIVITY_TYPES=commits,issues EMAILS=author@example.test SINCE='2021-01-01 00:00:00' \
    MIRROR_URL=https://github.com/bob/pat-mirror MIRROR_NAME=greens SCHEDULER=manual SYNC_HOUR=0
  greens_save_config "$CONFIG_FILE" SOURCE_PROVIDER WORK_DIR REMOTE_PREFIX GITHUB_USERNAME GITHUB_TOKEN ACTIVITY_TYPES EMAILS SINCE \
    MIRROR_URL MIRROR_DIR CACHE_DIR LOG_DIR MIRROR_EMAIL MIRROR_NAME PERSONAL_GH_USER SCHEDULER SYNC_HOUR
  unset GITHUB_TOKEN
  {
    printf 'y\n'
    printf '\n%.0s' {1..13}
    printf 'y\n'
  } | CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/setup.sh" > "$ACCOUNT_TEST/pat-setup-output" 2>&1 || {
    cat "$ACCOUNT_TEST/pat-setup-output"; fail "PAT migration and initial sync";
  }
  bash -c 'source "$1"; [[ "$GITHUB_TOKEN" == fixture-pat && "$SOURCE_1_USERNAME" == pat ]]' bash "$CONFIG_FILE" || fail "migration deleted the only saved PAT"
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 1 ]] || fail "initial sync did not use retained PAT"
  FORCE=1 CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/sync.sh" > "$ACCOUNT_TEST/pat-fresh-output" 2>&1 || {
    cat "$ACCOUNT_TEST/pat-fresh-output"; fail "fresh sync lost migrated PAT";
  }
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 1 ]] || fail "fresh PAT sync duplicated activities"
)

# On a clean installation, the ambient helper cannot read either work group.
# Each failed probe must allow selecting its own valid stored work account.
export REAL_GIT
REAL_GIT="$(command -v git)"
cat > "$ACCOUNT_TEST/bin/git" <<'MOCK'
#!/bin/bash
set -eu
url="" operation="" gitdir=""
for arg in "$@"; do
  case "$arg" in ls-remote|fetch|clone) operation="$arg" ;; --git-dir=*) gitdir="$arg" ;; https://github.com/*|https://*@github.com/*) url="$arg" ;; esac
done
if [[ "$operation" == fetch && -z "$url" && -n "$gitdir" ]]; then
  url="$("$REAL_GIT" "$gitdir" config remote.origin.url)"
fi
if [[ -n "$operation" ]]; then
  case "$url" in
    https://github.com/team/repo|https://alice@github.com/TeAm/RePo) [[ "${GH_TOKEN:-}" == fixture-alice ]] || exit 1 ;;
    https://github.com/otherteam/repo) [[ "${GH_TOKEN:-}" == fixture-carol ]] || exit 1 ;;
    https://bob@github.com/bob/select-mirror) [[ "${GH_TOKEN:-}" == fixture-bob ]] || exit 1 ;;
  esac
fi
exec "$REAL_GIT" "$@"
MOCK
chmod +x "$ACCOUNT_TEST/bin/git"
mkdir -p "$ACCOUNT_TEST/setup-work"
"$REAL_GIT" clone --quiet "$ACCOUNT_TEST/source.git" "$ACCOUNT_TEST/setup-work/team"
"$REAL_GIT" clone --quiet "$ACCOUNT_TEST/source.git" "$ACCOUNT_TEST/setup-work/team-copy"
"$REAL_GIT" clone --quiet "$ACCOUNT_TEST/source.git" "$ACCOUNT_TEST/setup-work/otherteam"
"$REAL_GIT" -C "$ACCOUNT_TEST/setup-work/team" remote set-url origin https://alice@github.com/TeAm/RePo
"$REAL_GIT" -C "$ACCOUNT_TEST/setup-work/team-copy" remote set-url origin https://github.com/team/repo
"$REAL_GIT" -C "$ACCOUNT_TEST/setup-work/otherteam" remote set-url origin https://github.com/otherteam/repo
"$REAL_GIT" config --global --add url."$ACCOUNT_TEST/source.git".insteadOf https://github.com/otherteam/repo
"$REAL_GIT" config --global --add url."$ACCOUNT_TEST/source.git".insteadOf https://alice@github.com/TeAm/RePo
"$REAL_GIT" init --bare --quiet "$ACCOUNT_TEST/select-mirror.git"
"$REAL_GIT" --git-dir="$ACCOUNT_TEST/select-mirror.git" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" config --global url."$ACCOUNT_TEST/select-mirror.git".insteadOf https://bob@github.com/bob/select-mirror
touch "$ACCOUNT_TEST/setup-active"
{
  printf '%s\n\n' "$ACCOUNT_TEST/setup-work"
  printf 'author@example.test\ncarol\ncommits, issues, commits\n2021-01-01\n'
  printf 'author@example.test\nalice\ncommits\n2021-01-01\n'
  printf 'bob\nmirror@example.test\ngreens\nhttps://bob@github.com/bob/select-mirror\n%s\nmanual\n0\ny\n' "$ACCOUNT_TEST/select-mirror"
} | CONTRIB_MIRROR_CONFIG="$ACCOUNT_TEST/select-config" bash "$ROOT/setup.sh" > "$ACCOUNT_TEST/select-output" 2>&1 || {
  cat "$ACCOUNT_TEST/select-output"; fail "clean HTTPS setup could not select work accounts";
}
bash -c 'source "$1"; [[ "$SOURCE_1_USERNAME" == carol && "$SOURCE_2_USERNAME" == alice && "$SOURCE_1_ACCESS_MODE" == remote && "$SOURCE_2_ACCESS_MODE" == remote && "$SOURCE_1_ACTIVITY_TYPES" == commits,issues ]]' bash "$ACCOUNT_TEST/select-config" || fail "setup did not retain selected accounts and normalized activity"
[[ "$("$REAL_GIT" -C "$ACCOUNT_TEST/select-mirror" rev-list --count HEAD)" == 3 ]] || fail "initial sync omitted a selected source or API activity"
[[ "$("$REAL_GIT" -C "$ACCOUNT_TEST/setup-work/team" config remote.origin.url)" == https://alice@github.com/TeAm/RePo ]] || fail "setup rewrote source transport casing"
bash -c 'source "$1/lib/common.sh"; source "$1/lib/gitlab.sh"; source "$2"; CACHE_DIR="$ACCOUNT_TEST/unused-cache"; greens_mixed_discover_checkouts' bash "$ROOT" "$ACCOUNT_TEST/select-config" > "$ACCOUNT_TEST/case-checkouts"
[[ "$(wc -l < "$ACCOUNT_TEST/case-checkouts" | tr -d ' ')" == 3 ]] || fail "case normalization omitted a checkout"
rm "$ACCOUNT_TEST/setup-active"
FORCE=1 CONTRIB_MIRROR_CONFIG="$ACCOUNT_TEST/select-config" bash "$ROOT/sync.sh" > "$ACCOUNT_TEST/select-fresh-output" 2>&1 || {
  cat "$ACCOUNT_TEST/select-fresh-output"; fail "fresh sync lost selected HTTPS accounts";
}
[[ "$("$REAL_GIT" -C "$ACCOUNT_TEST/select-mirror" rev-list --count HEAD)" == 3 ]] || fail "fresh sync duplicated selected activities"
[[ ! -e "$ACCOUNT_TEST/switched" ]] || fail "account retry changed the active gh account"

# SSH transport succeeds independently of gh. An expired active API session
# must still allow selecting a stored source account during a fresh setup.
mkdir -p "$ACCOUNT_TEST/ssh-work"
"$REAL_GIT" clone --quiet "$ACCOUNT_TEST/source.git" "$ACCOUNT_TEST/ssh-work/repo"
"$REAL_GIT" -C "$ACCOUNT_TEST/ssh-work/repo" remote set-url origin git@github.com:team/repo.git
"$REAL_GIT" config --global --add url."$ACCOUNT_TEST/source.git".insteadOf git@github.com:team/repo.git
"$REAL_GIT" init --bare --quiet "$ACCOUNT_TEST/ssh-mirror.git"
"$REAL_GIT" --git-dir="$ACCOUNT_TEST/ssh-mirror.git" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" config --global url."$ACCOUNT_TEST/ssh-mirror.git".insteadOf https://github.com/bob/ssh-mirror
rm -f "$ACCOUNT_TEST/github-queries"
{
  printf '%s\n\n' "$ACCOUNT_TEST/ssh-work"
  printf 'author@example.test\ncommits, issues\nALICE\n2021-01-01\n'
  printf 'BOB\nmirror@example.test\ngreens\nhttps://github.com/bob/ssh-mirror\n%s\nmanual\n0\ny\n' "$ACCOUNT_TEST/ssh-mirror"
} | CONTRIB_MIRROR_CONFIG="$ACCOUNT_TEST/ssh-config" bash "$ROOT/setup.sh" > "$ACCOUNT_TEST/ssh-output" 2>&1 || {
  cat "$ACCOUNT_TEST/ssh-output"; fail "fresh SSH setup could not select a valid API account";
}
grep -q 'username to retry API access' "$ACCOUNT_TEST/ssh-output" || fail "SSH setup did not offer API account selection"
bash -c 'source "$1"; [[ "$SOURCE_1_USERNAME" == ALICE && "$PERSONAL_GH_USER" == BOB && "$SOURCE_1_ACTIVITY_TYPES" == commits,issues && "$SOURCE_1_ACCESS_MODE" == remote ]]' bash "$ACCOUNT_TEST/ssh-config" || fail "SSH setup discarded requested API activity"
grep -q 'org:team' "$ACCOUNT_TEST/github-queries" || fail "selected SSH source API was not queried"
FORCE=1 CONTRIB_MIRROR_CONFIG="$ACCOUNT_TEST/ssh-config" bash "$ROOT/sync.sh" > "$ACCOUNT_TEST/ssh-fresh-output" 2>&1 || {
  cat "$ACCOUNT_TEST/ssh-fresh-output"; fail "fresh SSH sync lost selected API account";
}
[[ ! -e "$ACCOUNT_TEST/switched" ]] || fail "SSH API retry changed the active account"
echo "PASS: concurrent API accounts and caches, URL credentials, clone hosts, account casing, and PAT priority"
echo "PASS: PAT migration, transport-only credentials, and clean HTTPS account selection"
echo "PASS: case-insensitive GitHub setup and fresh SSH API account selection"
