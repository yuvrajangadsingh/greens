#!/bin/bash
# GitHub repository identity is case-insensitive; generic Git paths are not.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY_TEST="$(mktemp -d)"
IDENTITY_TEST="$(cd "$IDENTITY_TEST" && pwd -P)"
trap 'rm -rf "$IDENTITY_TEST"' EXIT
export HOME="$IDENTITY_TEST/home" GIT_CONFIG_GLOBAL="$IDENTITY_TEST/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$IDENTITY_TEST/work"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/gitlab.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
git config --global user.name Fixture
git config --global user.email author@example.test
git config --global commit.gpgsign false
git init --quiet "$IDENTITY_TEST/base"
GIT_AUTHOR_DATE=2021-01-01T12:00:00Z GIT_COMMITTER_DATE=2021-01-01T12:00:00Z \
  git -C "$IDENTITY_TEST/base" commit --quiet --allow-empty -m private
checkout() {
  git clone --quiet "$IDENTITY_TEST/base" "$IDENTITY_TEST/work/$1"
  git -C "$IDENTITY_TEST/work/$1" remote set-url origin "$2"
}
checkout github-upper git@github.com:Team/Repo.git
checkout github-lower https://github.com/team/repo.git
checkout ghe-upper ssh://git@enterprise.example:2222/TEAM/Repo.git
checkout ghe-lower git@enterprise-work:team/repo.git
checkout generic-upper git@forge.example:team/Repo.git
checkout generic-lower git@forge.example:team/repo.git

# Values are consumed dynamically by the indexed collector. Retain mixed-case
# saved owners to cover existing configurations as well as new setup output.
# shellcheck disable=SC2034
SOURCE_COUNT=3 SOURCE_1_PROVIDER=github SOURCE_1_API_HOST=github.com SOURCE_1_REMOTE_HOSTS=github.com SOURCE_1_ORGANIZATION=TEAM \
SOURCE_1_EMAILS=author@example.test SOURCE_1_SINCE=2021-01-01 SOURCE_1_ACTIVITY_TYPES=commits SOURCE_1_ACCESS_MODE=local \
SOURCE_2_PROVIDER=github SOURCE_2_API_HOST=github.enterprise.example SOURCE_2_REMOTE_HOSTS=enterprise.example,enterprise-work SOURCE_2_ORGANIZATION=TeAm \
SOURCE_2_EMAILS=author@example.test SOURCE_2_SINCE=2021-01-01 SOURCE_2_ACTIVITY_TYPES=commits SOURCE_2_ACCESS_MODE=local \
SOURCE_3_PROVIDER=git SOURCE_3_API_HOST=forge.example SOURCE_3_REMOTE_HOSTS=forge.example SOURCE_3_ORGANIZATION=team \
SOURCE_3_EMAILS=author@example.test SOURCE_3_SINCE=2021-01-01 SOURCE_3_ACTIVITY_TYPES=commits SOURCE_3_ACCESS_MODE=local
WORK_DIRS="$IDENTITY_TEST/work" CONFIG_FILE="$IDENTITY_TEST/config" CACHE_DIR="$IDENTITY_TEST/cache"
RUN_TMP="$IDENTITY_TEST/run" SUCCESS_STAMP_FILE="$IDENTITY_TEST/stamp"
MIRROR_DIR="$IDENTITY_TEST/mirror" MIRROR_EMAIL=mirror@example.test MIRROR_NAME=greens
mkdir -p "$CACHE_DIR" "$RUN_TMP"
git init --bare --quiet "$IDENTITY_TEST/mirror.git"
git init --quiet "$MIRROR_DIR"
git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
git -C "$MIRROR_DIR" remote add origin "$IDENTITY_TEST/mirror.git"
# Preserve already mirrored activities from pre-normalization builds. Public
# GitHub has only its original URL; Enterprise has only an old cached key with
# casing that no current URL retains. Neither may be emitted a second time.
sha="$(git -C "$IDENTITY_TEST/base" rev-parse HEAD)"
for old_key in "github.com/Team/Repo/commit/$sha" "github.enterprise.example/tEaM/rEpO/commit/$sha"; do
  marker="$(printf '%s' "$old_key" | greens_hash)"
  GIT_AUTHOR_DATE=2021-01-01T12:00:00Z GIT_COMMITTER_DATE=2021-01-01T12:00:00Z \
    git -C "$MIRROR_DIR" commit --quiet --allow-empty -m "$(printf 'sync\n\nGreens-Activity: %s' "$marker")"
done
mkdir -p "$CACHE_DIR/activity-state/$(greens_scheduler_id)-old-scope"
jq -nc --arg key "github.enterprise.example/tEaM/rEpO/commit/$sha" '{key:$key}' > "$CACHE_DIR/activity-state/$(greens_scheduler_id)-old-scope/retained.jsonl"
git -C "$MIRROR_DIR" push --quiet origin HEAD
log() { printf '%s\n' "$*"; }
mirror_visibility() { echo public; }
greens_mixed_discover_checkouts > "$IDENTITY_TEST/checkouts"
greens_mixed_discover_sources > "$IDENTITY_TEST/sources"
[[ "$(wc -l < "$IDENTITY_TEST/checkouts" | tr -d ' ')" == 6 ]] || fail "omitted a checkout with different casing"
[[ "$(wc -l < "$IDENTITY_TEST/sources" | tr -d ' ')" == 4 ]] || fail "wrong provider-specific deduplication"
grep -q 'github.com/team/repo' "$IDENTITY_TEST/sources" || fail "GitHub identity was not canonicalized"
grep -q 'github.enterprise.example/team/repo' "$IDENTITY_TEST/sources" || fail "Enterprise aliases were not canonicalized"
mv "$IDENTITY_TEST/work/github-lower" "$IDENTITY_TEST/not-yet-discovered"
greens_mixed_sync > "$IDENTITY_TEST/output" 2>&1 || { cat "$IDENTITY_TEST/output"; fail "identity sync"; }
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 4 ]] || fail "one SHA mirrored more than once per repository identity"
[[ "$(jq -s '[.[] | select(.key|startswith("ssh://git@forge.example/~/team/"))] | length' "$RUN_TMP/records")" == 2 ]] || fail "merged case-sensitive generic Git paths"
mv "$IDENTITY_TEST/not-yet-discovered" "$IDENTITY_TEST/work/github-lower"
greens_mixed_sync >> "$IDENTITY_TEST/output" 2>&1 || { cat "$IDENTITY_TEST/output"; fail "identity rerun"; }
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 4 ]] || fail "a newly discovered case variant duplicated activities"
[[ "$(git -C "$IDENTITY_TEST/work/github-upper" config remote.origin.url)" == git@github.com:Team/Repo.git ]] || fail "changed source URL casing"
# API review keys retain their case-sensitive timestamp suffix. A prior
# mixed-case owner marker skips only that review observation, not later ones.
old_review='github.com/TEAM/github/reviews/77/2021-01-02T12:00:00Z'
new_review='github.com/team/github/reviews/77/2021-01-02T12:00:00Z'
marker="$(printf '%s' "$old_review" | greens_hash)"
git -C "$MIRROR_DIR" commit --quiet --allow-empty -m "$(printf 'sync\n\nGreens-Activity: %s' "$marker")"
jq -nc --arg key "$new_review" '{key:$key,date:"2021-01-02 12:00:00 +0000",epoch:1609588800,kind:"reviews",project:"team/repo"}' > "$RUN_TMP/review-records"
: > "$RUN_TMP/review-publish"
greens_mirror_mixed_records "$RUN_TMP/review-records" "$RUN_TMP/review-publish" >> "$IDENTITY_TEST/output" 2>&1 || { cat "$IDENTITY_TEST/output"; fail "historical review marker"; }
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 5 ]] || fail "duplicated historical review"
jq '.key |= sub("2021-01-02T";"2021-01-03T") | .date="2021-01-03 12:00:00 +0000" | .epoch=1609675200' "$RUN_TMP/review-records" > "$RUN_TMP/later-review-records"
greens_mirror_mixed_records "$RUN_TMP/later-review-records" "$RUN_TMP/review-publish" >> "$IDENTITY_TEST/output" 2>&1 || { cat "$IDENTITY_TEST/output"; fail "later review marker"; }
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 6 ]] || fail "dropped later review observation"
# Generic endpoints on the same host/path must be fetched independently. Both
# SSH and HTTPS use real Git transports rewritten to separate local bare repos.
(
  WORK_DIRS="$IDENTITY_TEST/port-work" CONFIG_FILE="$IDENTITY_TEST/port-config"
  CACHE_DIR="$IDENTITY_TEST/port-cache" RUN_TMP="$IDENTITY_TEST/port-run"
  MIRROR_DIR="$IDENTITY_TEST/port-mirror" SUCCESS_STAMP_FILE="$IDENTITY_TEST/port-stamp"
  # Values are consumed dynamically by the indexed collector.
  # shellcheck disable=SC2034
  SOURCE_COUNT=1 SOURCE_1_PROVIDER=git SOURCE_1_API_HOST=forge.example SOURCE_1_REMOTE_HOSTS=forge.example \
    SOURCE_1_ORGANIZATION=team SOURCE_1_ACCESS_MODE=remote
  mkdir -p "$WORK_DIRS" "$CACHE_DIR" "$RUN_TMP"
  for port in 2222 2223 8443 9443; do
    case "$port" in 222*) scheme=ssh ;; *) scheme=https ;; esac
    url="$scheme://git@forge.example:$port/team/repo.git"
    git init --quiet "$WORK_DIRS/$port"
    GIT_AUTHOR_DATE="2021-01-01T12:00:${port: -2}Z" GIT_COMMITTER_DATE="2021-01-01T12:00:${port: -2}Z" \
      git -C "$WORK_DIRS/$port" commit --quiet --allow-empty -m "endpoint $port"
    git clone --bare --quiet "$WORK_DIRS/$port" "$IDENTITY_TEST/remote-$port.git"
    git -C "$WORK_DIRS/$port" remote add origin "$url"
    git config --global url."$IDENTITY_TEST/remote-$port.git".insteadOf "$url"
  done
  git init --bare --quiet "$IDENTITY_TEST/port-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$IDENTITY_TEST/port-mirror.git"
  greens_mixed_discover_sources > "$IDENTITY_TEST/port-sources"
  [[ "$(wc -l < "$IDENTITY_TEST/port-sources" | tr -d ' ')" == 4 ]] || fail "generic endpoint ports were merged"
  for port in 2222 2223 8443 9443; do
    grep -Fq "forge.example:$port/team/repo" "$IDENTITY_TEST/port-sources" || fail "lost generic port $port"
  done
  greens_mixed_sync > "$IDENTITY_TEST/port-output" 2>&1 || { cat "$IDENTITY_TEST/port-output"; fail "generic port sync"; }
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 4 ]] || fail "one generic endpoint's commits were omitted"
  greens_mixed_sync >> "$IDENTITY_TEST/port-output" 2>&1 || { cat "$IDENTITY_TEST/port-output"; fail "generic port rerun"; }
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 4 ]] || fail "generic endpoint rerun duplicated activities"
) || fail "generic Git endpoint port regression"
# SSH login homes are separate generic endpoints. Preserve login casing, while
# recognizing SCP and ssh:// forms of the same login/repository as one source.
(
  WORK_DIRS="$IDENTITY_TEST/login-work" CONFIG_FILE="$IDENTITY_TEST/login-config"
  CACHE_DIR="$IDENTITY_TEST/login-cache" RUN_TMP="$IDENTITY_TEST/login-run"
  MIRROR_DIR="$IDENTITY_TEST/login-mirror" SUCCESS_STAMP_FILE="$IDENTITY_TEST/login-stamp"
  # Values are consumed dynamically by the indexed collector.
  # shellcheck disable=SC2034
  SOURCE_COUNT=1 SOURCE_1_PROVIDER=git SOURCE_1_API_HOST=forge.example SOURCE_1_REMOTE_HOSTS=forge.example \
    SOURCE_1_ORGANIZATION=project SOURCE_1_ACCESS_MODE=remote
  mkdir -p "$WORK_DIRS" "$CACHE_DIR" "$RUN_TMP"
  slot=0
  for login in alice bob Alice; do
    slot="$((slot + 1))"
    git init --quiet "$WORK_DIRS/login-$slot"
    GIT_AUTHOR_DATE=2021-01-01T12:00:00Z GIT_COMMITTER_DATE=2021-01-01T12:00:00Z \
      git -C "$WORK_DIRS/login-$slot" commit --quiet --allow-empty -m "login home $login"
    git clone --bare --quiet "$WORK_DIRS/login-$slot" "$IDENTITY_TEST/login-$slot.git"
    url="$login@forge.example:project.git"
    git -C "$WORK_DIRS/login-$slot" remote add origin "$url"
    git config --global url."$IDENTITY_TEST/login-$slot.git".insteadOf "$url"
  done
  git clone --quiet "$IDENTITY_TEST/login-2.git" "$WORK_DIRS/bob-uri"
  git -C "$WORK_DIRS/bob-uri" remote set-url origin ssh://bob@forge.example/~/project.git
  git config --global --add url."$IDENTITY_TEST/login-2.git".insteadOf ssh://bob@forge.example/~/project.git
  for kind in absolute plain; do
    git init --quiet "$WORK_DIRS/$kind"
    GIT_AUTHOR_DATE=2021-01-01T12:00:00Z GIT_COMMITTER_DATE=2021-01-01T12:00:00Z \
      git -C "$WORK_DIRS/$kind" commit --quiet --allow-empty -m "distinct $kind path"
    git clone --bare --quiet "$WORK_DIRS/$kind" "$IDENTITY_TEST/$kind.git"
    if [[ "$kind" == absolute ]]; then url=alice@forge.example:/project.git; else url=alice@forge.example:project; fi
    git -C "$WORK_DIRS/$kind" remote add origin "$url"
    git config --global url."$IDENTITY_TEST/$kind.git".insteadOf "$url"
  done
  git clone --quiet "$IDENTITY_TEST/absolute.git" "$WORK_DIRS/absolute-uri"
  git -C "$WORK_DIRS/absolute-uri" remote set-url origin ssh://alice@forge.example/project.git
  git config --global --add url."$IDENTITY_TEST/absolute.git".insteadOf ssh://alice@forge.example/project.git
  git init --bare --quiet "$IDENTITY_TEST/login-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$IDENTITY_TEST/login-mirror.git"
  greens_mixed_discover_sources > "$IDENTITY_TEST/login-sources"
  [[ "$(wc -l < "$IDENTITY_TEST/login-sources" | tr -d ' ')" == 5 ]] || fail "SSH login/path endpoints were merged or equivalent URLs were duplicated"
  greens_mixed_sync > "$IDENTITY_TEST/login-output" 2>&1 || { cat "$IDENTITY_TEST/login-output"; fail "SSH login sync"; }
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 5 ]] || fail "SSH login or absolute/relative path source activity omitted"
  greens_mixed_sync >> "$IDENTITY_TEST/login-output" 2>&1 || { cat "$IDENTITY_TEST/login-output"; fail "SSH login rerun"; }
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 5 ]] || fail "SSH login rerun duplicated activities"
) || fail "generic Git SSH login regression"
echo "PASS: distinct SSH login homes and casing, equivalent URL forms, and idempotent collection"
echo "PASS: GitHub and Enterprise casing, historical markers, aliases, and case-sensitive generic Git paths"

echo "PASS: independent SSH/HTTPS Git ports, complete remote collection, and idempotent reruns"

# Bracketed SCP IPv6 endpoints split at ]:, not the address's first colon.
(
  WORK_DIRS="$IDENTITY_TEST/ipv6-work" CONFIG_FILE="$IDENTITY_TEST/ipv6-config"
  CACHE_DIR="$IDENTITY_TEST/ipv6-cache" RUN_TMP="$IDENTITY_TEST/ipv6-run"
  MIRROR_DIR="$IDENTITY_TEST/ipv6-mirror" SUCCESS_STAMP_FILE="$IDENTITY_TEST/ipv6-stamp"
  # Values are consumed by indexed accessors.
  # shellcheck disable=SC2034
  SOURCE_COUNT=1 SOURCE_1_PROVIDER=git SOURCE_1_API_HOST='[::1]' SOURCE_1_REMOTE_HOSTS='[::1]' SOURCE_1_ORGANIZATION=team \
    SOURCE_1_ACTIVITY_TYPES=commits SOURCE_1_ACCESS_MODE=remote SOURCE_1_USERNAME='' SOURCE_1_EMAILS=author@example.test SOURCE_1_SINCE=2021-01-01
  mkdir -p "$WORK_DIRS" "$RUN_TMP" "$CACHE_DIR"
  scp_url='git@[::1]:team/repo.git' uri_url='ssh://git@[::1]/~/team/repo.git'
  [[ "$(greens_remote_identity "$scp_url" 1)" == "$uri_url" ]] || fail "IPv6 SCP address split inside brackets"
  [[ "$(greens_remote_host "$(greens_remote_identity "$scp_url" 1)")" == '[::1]' ]] || fail "IPv6 hostname was truncated"
  [[ "$(greens_remote_identity '[2001:DB8::1]:team/repo.git' 1)" == 'ssh://[2001:db8::1]/~/team/repo.git' ]] || fail "IPv6 SCP without login"
  for kind in scp uri; do
    git clone --quiet "$IDENTITY_TEST/base" "$WORK_DIRS/$kind"
    if [[ "$kind" == scp ]]; then url="$scp_url"; else url="$uri_url"; fi
    git -C "$WORK_DIRS/$kind" remote set-url origin "$url"
    git config --global --add url."$IDENTITY_TEST/base".insteadOf "$url"
  done
  git init --bare --quiet "$IDENTITY_TEST/ipv6-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$IDENTITY_TEST/ipv6-mirror.git"
  greens_mixed_discover_sources > "$IDENTITY_TEST/ipv6-sources"
  [[ "$(wc -l < "$IDENTITY_TEST/ipv6-sources" | tr -d ' ')" == 1 ]] || fail "IPv6 URL aliases did not deduplicate"
  greens_mixed_sync > "$IDENTITY_TEST/ipv6-output" 2>&1 || { cat "$IDENTITY_TEST/ipv6-output"; fail "IPv6 source sync"; }
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 1 ]] || fail "IPv6 aliases mirrored duplicate activity"
  greens_mixed_sync >> "$IDENTITY_TEST/ipv6-output" 2>&1 || { cat "$IDENTITY_TEST/ipv6-output"; fail "IPv6 rerun"; }
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 1 ]] || fail "IPv6 rerun duplicated activity"
) || fail "bracketed IPv6 identity regression"
echo "PASS: bracketed IPv6 SCP/URI aliases group together and mirror each activity once"
