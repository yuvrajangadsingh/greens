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
[[ "$(jq -s '[.[] | select(.key|startswith("forge.example/team/"))] | length' "$RUN_TMP/records")" == 2 ]] || fail "merged case-sensitive generic Git paths"
mv "$IDENTITY_TEST/not-yet-discovered" "$IDENTITY_TEST/work/github-lower"
greens_mixed_sync >> "$IDENTITY_TEST/output" 2>&1 || { cat "$IDENTITY_TEST/output"; fail "identity rerun"; }
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 4 ]] || fail "a newly discovered case variant duplicated activities"
[[ "$(git -C "$IDENTITY_TEST/work/github-upper" config remote.origin.url)" == git@github.com:Team/Repo.git ]] || fail "changed source URL casing"
echo "PASS: GitHub and Enterprise casing deduplication, aliases, and case-sensitive generic Git paths"
