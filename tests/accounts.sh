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
source "$ROOT/lib/common.sh"
source "$ROOT/lib/gitlab.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$ACCOUNT_TEST/bin/gh" <<'MOCK'
#!/bin/bash
set -eu
case "$*" in
  'auth switch '*) touch "$ACCOUNT_TEST/switched"; exit 99 ;;
  'auth status'*) exit 1 ;; # The active account has expired.
  'auth token --hostname '*' --user '*)
    user="${*: -1}"
    case "$user" in alice|bob) printf 'fixture-%s\n' "$user" ;; *) exit 1 ;; esac ;;
  'auth token --hostname '*) exit 1 ;;
  'auth git-credential get')
    cat >/dev/null
    printf 'username=%s\npassword=%s\n' "${GH_TOKEN#fixture-}" "$GH_TOKEN" ;;
  'api --hostname '*' user --jq .login')
    case "${GH_TOKEN:-}" in fixture-alice|fixture-bob|fixture-pat) echo "${GH_TOKEN#fixture-}" ;; *) exit 1 ;; esac ;;
  'api --hostname '*' users/team --jq .type') echo Organization ;;
  'api --hostname '*' --paginate -X GET search/issues'*) echo '{"items":[]}' ;;
  'search issues --author=alice '*) [[ "$GH_TOKEN" == fixture-alice ]] || exit 1; echo '2021-01-02T12:00:00Z' ;;
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
MIRROR_DIR="$ACCOUNT_TEST/mirror" PERSONAL_GH_USER=bob
printf 'protocol=https\nhost=github.com\n\n' |
  greens_mirror_git credential fill > "$ACCOUNT_TEST/mirror-credentials"
grep -qx username=bob "$ACCOUNT_TEST/mirror-credentials" || fail "destination inherited source Git credentials"

# Exercise the complete indexed collector while gh auth status fails. The Git
# transports are local bare repositories, with the original HTTPS identities.
# Config values are read dynamically by the collector.
# shellcheck disable=SC2034
SOURCE_COUNT=1 SOURCE_1_PROVIDER=github SOURCE_1_API_HOST=github.com SOURCE_1_REMOTE_HOSTS=github.com \
SOURCE_1_ORGANIZATION=team SOURCE_1_USERNAME=alice SOURCE_1_EMAILS=author@example.test \
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

# Environment-only PATs still work, but may not impersonate a different actor.
[[ "$(GH_TOKEN=fixture-pat greens_gh_api_as github.com pat user --jq .login)" == pat ]] || fail "PAT-only account"
[[ "$(GH_ENTERPRISE_TOKEN=fixture-bob greens_gh_api_as github.example alice user --jq .login)" == alice ]] || fail "Enterprise named account isolation"
if GH_TOKEN=fixture-bob greens_gh_api_as github.com missing user --jq .login > /dev/null 2>&1; then fail "accepted mismatched PAT actor"; fi

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
  WORK_DIR="$ACCOUNT_TEST/source" REMOTE_PREFIX="$ACCOUNT_TEST/" GITHUB_USERNAME=alice GITHUB_ORG=team \
    ACTIVITY_TYPES=commits,issues EMAILS=author@example.test SINCE=2021-01-01
  greens_save_config "$CONFIG_FILE" WORK_DIR REMOTE_PREFIX GITHUB_USERNAME GITHUB_ORG ACTIVITY_TYPES EMAILS SINCE \
    MIRROR_DIR CACHE_DIR LOG_DIR MIRROR_EMAIL PERSONAL_GH_USER
  FORCE=1 CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/sync.sh" > "$ACCOUNT_TEST/legacy-output" 2>&1 || {
    cat "$ACCOUNT_TEST/legacy-output"; fail "legacy account isolation";
  }
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 2 ]] || fail "legacy source API activity was skipped"
)
[[ ! -e "$ACCOUNT_TEST/switched" ]] || fail "legacy sync changed the shared account"
echo "PASS: concurrent API accounts, isolated Git helpers, expired active session, and PAT identity"
