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
[[ "$(jq -s '[.[] | select(.key|startswith("forge.example/team/"))] | length' "$RUN_TMP/records")" == 2 ]] || fail "merged case-sensitive generic Git paths"
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
echo "PASS: GitHub and Enterprise casing, historical markers, aliases, and case-sensitive generic Git paths"
