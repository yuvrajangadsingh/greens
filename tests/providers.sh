#!/bin/bash
# Offline integration tests: real Git repositories, fixture GitLab API responses.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT HOME="$TEST_ROOT/home" GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TEST_ROOT/gitconfig"
mkdir -p "$HOME" "$TEST_ROOT/bin"
export PATH="$TEST_ROOT/bin:$PATH"
cat > "$TEST_ROOT/bin/crontab" <<'MOCK'
#!/bin/bash
case "$1" in
  -l) [[ -f "$TEST_ROOT/crontab" ]] && cat "$TEST_ROOT/crontab" ;;
  -) cat > "$TEST_ROOT/crontab" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/crontab"
git config --global user.name "Fixture Author"
git config --global user.email "author@example.test"
git config --global commit.gpgsign false
source "$ROOT/lib/common.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Shell configuration must round-trip literally, with environment precedence.
VALUE=$'a space "quote" $HOME $(touch SHOULD_NOT_EXIST) \' braces } { %\nsecond line'
greens_save_config "$TEST_ROOT/config-roundtrip" VALUE
expected="$VALUE"
unset VALUE
source "$TEST_ROOT/config-roundtrip"
[[ "$VALUE" == "$expected" ]] || fail "configuration quoting"
VALUE=override
source "$TEST_ROOT/config-roundtrip"
[[ "$VALUE" == override ]] || fail "environment precedence"
[[ ! -f SHOULD_NOT_EXIST ]] || fail "configuration executed input"
[[ "$(greens_remote_identity 'ssh://git@forge.example:2222/group/sub/repo.git')" == forge.example/group/sub/repo ]] || fail "SSH URL normalization"
[[ "$(greens_remote_identity 'https://forge.example/group/sub/repo')" == forge.example/group/sub/repo ]] || fail "HTTPS normalization"

mkdir -p "$TEST_ROOT/scan-root/immediate/.git" "$TEST_ROOT/scan-root/worktree" "$TEST_ROOT/scan-root/nested/deep/.git" "$TEST_ROOT/scan-root/.git"
: > "$TEST_ROOT/scan-root/worktree/.git"
[[ "$(greens_count_repositories "$TEST_ROOT/scan-root" in-root)" == 2 ]] || fail "in-root repository depth"
[[ "$(greens_count_repositories "$TEST_ROOT/scan-root" recursive)" == 4 ]] || fail "recursive repository depth"

mkdir -p "$TEST_ROOT/work/nested" "$TEST_ROOT/remotes"
git init --bare --quiet "$TEST_ROOT/remotes/source.git"
git init --bare --quiet "$TEST_ROOT/remotes/mirror.git"
git init --quiet "$TEST_ROOT/work/source"
git -C "$TEST_ROOT/work/source" symbolic-ref HEAD refs/heads/main
git -C "$TEST_ROOT/work/source" remote add origin "$TEST_ROOT/remotes/source.git"
commit_fixture() {
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" \
    git -C "$TEST_ROOT/work/source" -c user.email="${2:-author@example.test}" commit --quiet --allow-empty -m "secret source subject"
}
commit_fixture '2021-02-03T12:00:00Z'
commit_fixture '2021-02-03T12:00:00Z'
commit_fixture '2021-02-03T12:00:01Z' 'other@example.test'
# One authored commit exists only through an MR ref (its source branch is gone).
git -C "$TEST_ROOT/work/source" push --quiet origin HEAD~2:refs/heads/main HEAD~1:refs/merge-requests/1/head
git --git-dir="$TEST_ROOT/remotes/source.git" symbolic-ref HEAD refs/heads/main
git --git-dir="$TEST_ROOT/remotes/mirror.git" symbolic-ref HEAD refs/heads/main
git -C "$TEST_ROOT/work/source" remote set-url origin git@forge.example:team/repo.git
git config --global url."$TEST_ROOT/remotes/source.git".insteadOf git@forge.example:team/repo.git
git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf https://forge.example/team/repo
git clone --quiet --branch main https://forge.example/team/repo "$TEST_ROOT/work/nested/duplicate"
git -C "$TEST_ROOT/work/source" worktree add --quiet --detach "$TEST_ROOT/work/nested/worktree" HEAD
git init --quiet "$TEST_ROOT/mirror"
git -C "$TEST_ROOT/mirror" symbolic-ref HEAD refs/heads/main
git -C "$TEST_ROOT/mirror" remote add origin "$TEST_ROOT/remotes/mirror.git"
cat > "$TEST_ROOT/bin/glab" <<'MOCK'
#!/bin/bash
set -eu
if [[ -f "$TEST_ROOT/forbid-glab" ]]; then touch "$TEST_ROOT/glab-called"; exit 99; fi
if [[ "$*" == "auth status --hostname forge.example" ]]; then exit 0; fi
[[ ! -f "$TEST_ROOT/api-fails" ]] || exit 1
if [[ -f "$TEST_ROOT/worker-fails" && "$4" == projects/7/issues/4/discussions* ]]; then exit 1; fi
echo "$4" >> "$TEST_ROOT/api-calls"
case "$4" in
  metadata) echo '{"version":"18.0.0","revision":"fixture"}' ;;
  user) echo '{"id":42,"username":"fixture"}' ;;
  projects/team%2Frepo) echo '{"id":7}' ;;
  users/42/events*)
    echo '[{"id":9,"author_id":42,"project_id":7,"target_type":"MergeRequest","action_name":"approved","created_at":"2021-02-03T12:00:00.123Z"},{"id":10,"author_id":99,"project_id":7,"target_type":"MergeRequest","action_name":"approved","created_at":"2021-02-03T12:00:00Z"},{"id":11,"author_id":42,"project_id":8,"target_type":"MergeRequest","action_name":"approved","created_at":"2021-02-03T12:00:00Z"}]' ;;
  projects/7/merge_requests\?*)
    echo '[{"id":21,"iid":1,"author":{"id":42},"created_at":"2021-02-03T12:00:00Z"}]' ;;
  projects/7/issues\?*)
    # Consecutive JSON arrays mimic glab --paginate output.
    echo '[{"id":22,"iid":2,"author":{"id":42},"created_at":"2021-02-03T12:00:00Z"}]'
    echo '[{"id":23,"iid":3,"author":{"id":99},"created_at":"2021-02-03T12:00:00Z"},{"id":24,"iid":4,"author":{"id":99},"created_at":"2021-02-03T12:00:00Z"},{"id":25,"iid":5,"author":{"id":99},"created_at":"2021-02-03T12:00:00Z"},{"id":26,"iid":6,"author":{"id":99},"created_at":"2021-02-03T12:00:00Z"}]' ;;
  projects/7/merge_requests/1/discussions*)
    echo '[{"notes":[{"id":31,"author":{"id":42},"system":false,"type":"DiffNote","created_at":"2021-02-03T12:00:00.234Z","body":"secret comment"},{"id":99,"author":{"id":42},"system":true,"created_at":"2021-02-03T12:00:00Z","body":"system note"}]}]' ;;
  projects/7/issues/2/discussions*)
    echo '[{"notes":[{"id":32,"author":{"id":42},"system":false,"type":"DiscussionNote","created_at":"2021-02-03T12:00:00.345Z"}]}]' ;;
  projects/7/merge_requests/1/resource_state_events*)
    echo '[{"id":41,"user":{"id":42},"state":"merged","created_at":"2021-02-03T12:00:00Z"}]' ;;
  projects/7/issues/2/resource_state_events*)
    echo '[{"id":42,"user":{"id":42},"state":"closed","created_at":"2021-02-03T12:00:00Z"}]' ;;
  projects/7/issues/[3456]/*) echo '[]' ;;
  *) echo "Unexpected endpoint: $4" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/glab"
CONFIG_FILE="$TEST_ROOT/config"
# These defaults are consumed by name in greens_save_config.
# shellcheck disable=SC2034
SOURCE_PROVIDER=gitlab EMAILS=author@example.test MIRROR_EMAIL=mirror@example.test GITLAB_HOST=forge.example GITLAB_USERNAME=fixture ACTIVITY_TYPES=commits,mrs,issues,comments,approvals,merges,state_changes SINCE=2021-01-01
WORK_DIR="$TEST_ROOT/work"
MIRROR_DIR="$TEST_ROOT/mirror"
CACHE_DIR="$TEST_ROOT/cache"
LOG_DIR="$TEST_ROOT/logs"
greens_save_config "$CONFIG_FILE" SOURCE_PROVIDER WORK_DIR MIRROR_DIR CACHE_DIR LOG_DIR EMAILS MIRROR_EMAIL GITLAB_HOST GITLAB_USERNAME ACTIVITY_TYPES SINCE
run_sync() { CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" FORCE=1 bash "$ROOT/sync.sh" > "$TEST_ROOT/output" 2>&1 || { cat "$TEST_ROOT/output"; return 1; }; }
run_sync
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 9 ]] || { cat "$TEST_ROOT/output"; fail "expected nine distinct activities"; }
[[ "$(grep -c '^projects/team%2Frepo$' "$TEST_ROOT/api-calls")" == 1 ]] || fail "duplicate repository collection"
[[ "$(git -C "$MIRROR_DIR" log --format=%ae | sort -u)" == mirror@example.test ]] || fail "wrong author identity"
[[ -z "$(git -C "$MIRROR_DIR" ls-tree -r HEAD)" ]] || fail "source content in mirror"
if git -C "$MIRROR_DIR" log --format=%B | grep -Eq 'secret|forge.example|team/repo'; then fail "source metadata leaked"; fi
run_sync
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 9 ]] || fail "rerun duplicated activities"

checkpoint="$(cat "$CACHE_DIR"/activity-state/*/*.checkpoint)"
commit_fixture '2021-03-01T12:00:00Z'
git -C "$TEST_ROOT/work/source" push --quiet origin main
printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/remotes/mirror.git/hooks/pre-receive"
chmod +x "$TEST_ROOT/remotes/mirror.git/hooks/pre-receive"
if run_sync; then fail "push failure accepted"; fi
[[ "$(cat "$CACHE_DIR"/activity-state/*/*.checkpoint)" == "$checkpoint" ]] || fail "checkpoint advanced after failed push"
rm "$TEST_ROOT/remotes/mirror.git/hooks/pre-receive"
run_sync
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 10 ]] || fail "retry duplicated pending commit"
[[ "$(git --git-dir="$TEST_ROOT/remotes/mirror.git" rev-parse refs/heads/main)" == "$(git -C "$MIRROR_DIR" rev-parse HEAD)" ]] || fail "remote tip differs"
touch "$TEST_ROOT/api-fails"
if run_sync; then fail "API failure accepted"; fi
rm "$TEST_ROOT/api-fails"
checkpoint="$(cat "$CACHE_DIR"/activity-state/*/*.checkpoint)"
touch "$TEST_ROOT/worker-fails"
if run_sync; then fail "worker API failure accepted"; fi
rm "$TEST_ROOT/worker-fails"
[[ "$(cat "$CACHE_DIR"/activity-state/*/*.checkpoint)" == "$checkpoint" ]] || fail "worker failure advanced checkpoint"
[[ -z "$(git -C "$WORK_DIR/source" status --porcelain)" ]] || fail "source was modified"
echo "PASS: config, discovery, API pagination/filtering, stable IDs, privacy, and retry safety"

# Exercise the actual setup dialog with a different local config and mocked CLI
# sessions. All personal values must come from answers, not the implementation.
cat > "$TEST_ROOT/bin/gh" <<'MOCK'
#!/bin/bash
case "$*" in
  'auth status --active --hostname github.example') exit 0 ;;
  'auth switch --hostname github.example --user '*) printf '%s\n' "${*: -1}" > "$TEST_ROOT/github-example-active" ;;
  'auth switch --hostname github.com --user '*) exit 0 ;;
  'api --hostname github.example user') login="$(cat "$TEST_ROOT/github-example-active" 2>/dev/null || echo fixture-gh)"; printf '{"login":"%s"}\n' "$login" ;;
  'api --hostname github.example user --jq .login') cat "$TEST_ROOT/github-example-active" 2>/dev/null || echo fixture-gh ;;
  'api --hostname github.example / --jq .current_user_url') echo 'https://github.example/api/v3/user' ;;
  api\ --hostname\ github.example\ --paginate\ -X\ GET\ search/issues*)
    [[ "$(cat "$TEST_ROOT/github-example-active" 2>/dev/null || echo fixture-gh)" == fixture-gh ]] || exit 1
    if [[ "$*" == *'type:issue'* ]]; then
      echo '{"items":[{"id":502,"created_at":"2021-02-03T14:00:00Z","repository_url":"https://github.example/api/v3/repos/acme/app"}]}'
    else
      echo '{"items":[{"id":501,"created_at":"2021-02-03T13:00:00Z","updated_at":"2021-02-03T13:00:00Z","repository_url":"https://github.example/api/v3/repos/acme/app"}]}'
    fi
    ;;
  'api user --jq .login'|'api --hostname github.com user --jq .login') echo fixture ;;
  'api user/emails --jq '*|'api --hostname github.com user/emails --jq '*) echo mirror@example.test ;;
  'api repos/fixture/mirror') echo '{"private":true,"default_branch":"main"}' ;;
  'auth status'*) exit 0 ;;
  'repo view '*' --json visibility -q .visibility') echo "${FIXTURE_VISIBILITY:-PRIVATE}" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/gh"
git config --global url."$TEST_ROOT/remotes/mirror.git".insteadOf https://github.com/fixture/mirror
dialog_config="$TEST_ROOT/dialog/config"
{
  printf '%s\n\nforge.example\nauthor@example.test\nfixture\n2021-01-01\n' "$WORK_DIR"
  printf '\nfixture\nmirror@example.test\ngreens\n'
  printf 'https://github.com/fixture/mirror\n%s\nmanual\n0\nn\n' "$TEST_ROOT/dialog-mirror"
} | ACTIVITY_TYPES=commits,prs,issues CONTRIB_MIRROR_CONFIG="$dialog_config" bash "$ROOT/setup.sh" --in-root > "$TEST_ROOT/dialog-output" 2>&1 || {
  cat "$TEST_ROOT/dialog-output"; fail "setup dialog";
}
[[ -f "$dialog_config" ]] || fail "setup did not honor config location"
bash -c 'source "$1"; [[ "$SCAN_MODE" == in-root && "$SOURCE_COUNT" == 1 && "$SOURCE_1_PROVIDER" == gitlab && "$SOURCE_1_API_HOST" == forge.example && "$SOURCE_1_ACTIVITY_TYPES" == commits,mrs,issues && "$MIRROR_EMAIL" == mirror@example.test && "$SCHEDULER" == manual && -z "${SOURCE_PROVIDER:-}" ]]' bash "$dialog_config" || fail "dialog did not persist choices"
grep -q 'Activity types for forge.example/team \[commits,mrs,issues\]' "$TEST_ROOT/dialog-output" || fail "GitLab setup did not migrate prs to mrs"
CONTRIB_MIRROR_CONFIG="$dialog_config" bash "$ROOT/sync.sh" --status > "$TEST_ROOT/in-root-status"
grep -Fq "$WORK_DIR (1 repos)" "$TEST_ROOT/in-root-status" || fail "status ignored in-root scan mode"
dialog_hash="$(git hash-object "$dialog_config")"
printf 'n\n' | CONTRIB_MIRROR_CONFIG="$dialog_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/dialog-rerun-output" 2>&1 || fail "setup rerun summary"
[[ "$(git hash-object "$dialog_config")" == "$dialog_hash" ]] || fail "declined setup rerun changed config"
grep -q 'Current configuration:' "$TEST_ROOT/dialog-rerun-output" || fail "setup rerun omitted current summary"
grep -q 'Add another work directory' "$TEST_ROOT/dialog-output" || fail "setup did not offer another work directory"
if grep -qE 'separate GitHub accounts|Work GitHub org/owner name' "$TEST_ROOT/dialog-output"; then
  fail "GitLab-only setup displayed GitHub source prompts"
fi

# Older setup versions could leave an early default before the latest saved
# value. Loading must use the last assignment and the next save must clean it.
SYNC_HOUR=11 greens_save_config "$dialog_config" SYNC_HOUR
{ printf '%s\n' 'SYNC_HOUR="${SYNC_HOUR:-0}"'; cat "$dialog_config"; } > "$dialog_config.duplicate"
mv "$dialog_config.duplicate" "$dialog_config"

# An unreachable GitLab source can be confirmed as local-only before any glab
# authentication or activity prompt is attempted.
mkdir -p "$TEST_ROOT/local-dialog-work/repo"
git init --quiet "$TEST_ROOT/local-dialog-work/repo"
git -C "$TEST_ROOT/local-dialog-work/repo" remote add origin git@gitlab.com:offline/repo.git
git config --global --add url."$TEST_ROOT/missing/offline.git".insteadOf git@gitlab.com:offline/repo.git
local_dialog_config="$TEST_ROOT/local-dialog/config"
touch "$TEST_ROOT/forbid-glab"
{
  printf '%s\n\nauthor@example.test\ny\n2021-01-01\n' "$TEST_ROOT/local-dialog-work"
  printf '\n\n\nhttps://github.com/fixture/mirror\n%s\nmanual\n0\nn\n' "$TEST_ROOT/local-dialog-mirror"
} | CONTRIB_MIRROR_CONFIG="$local_dialog_config" bash "$ROOT/setup.sh" --in-root > "$TEST_ROOT/local-dialog-output" 2>&1 || {
  rm -f "$TEST_ROOT/forbid-glab"; cat "$TEST_ROOT/local-dialog-output"; fail "local-only setup dialog";
}
rm "$TEST_ROOT/forbid-glab"
[[ ! -e "$TEST_ROOT/glab-called" ]] || fail "local-only setup invoked glab"
bash -c 'source "$1"; [[ "$SOURCE_COUNT" == 1 && "$SOURCE_1_ACCESS_MODE" == local && "$SOURCE_1_ACTIVITY_TYPES" == commits && -z "$SOURCE_1_USERNAME" ]]' bash "$local_dialog_config" || fail "setup did not persist local-only source"
if grep -qE 'GitLab username|Activity types for gitlab.com/offline' "$TEST_ROOT/local-dialog-output"; then fail "local-only setup showed provider prompts"; fi

# A saved local source stays offline unless the user explicitly requests a
# remote retry during a later setup run.
rm -f "$TEST_ROOT/glab-called"; touch "$TEST_ROOT/forbid-glab"
{
  printf 'y\n'
  printf '\n%.0s' {1..12}
  printf 'n\n'
} | CONTRIB_MIRROR_CONFIG="$local_dialog_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/local-dialog-rerun-output" 2>&1 || {
  rm -f "$TEST_ROOT/forbid-glab"; cat "$TEST_ROOT/local-dialog-rerun-output"; fail "saved local-only setup rerun";
}
rm "$TEST_ROOT/forbid-glab"
[[ ! -e "$TEST_ROOT/glab-called" ]] || fail "saved local-only setup invoked glab"
grep -q 'Retry remote access for gitlab.com/offline' "$TEST_ROOT/local-dialog-rerun-output" || fail "saved local source did not offer remote retry"
bash -c 'source "$1"; [[ "$SOURCE_1_ACCESS_MODE" == local && "$SOURCE_1_ACTIVITY_TYPES" == commits ]]' bash "$local_dialog_config" || fail "saved local source did not remain local"

# GitHub prompts are conditional, every discovered owner gets a separate source
# record, and a dash skips a complete owner before its remaining prompts.
mkdir -p "$TEST_ROOT/github-dialog-work/one" "$TEST_ROOT/github-dialog-work/one-copy" "$TEST_ROOT/github-dialog-work/two" "$TEST_ROOT/github-dialog-work/three" "$TEST_ROOT/github-dialog-work/nested/four"
git init --quiet "$TEST_ROOT/github-dialog-work/one"
git init --quiet "$TEST_ROOT/github-dialog-work/one-copy"
git init --quiet "$TEST_ROOT/github-dialog-work/two"
git init --quiet "$TEST_ROOT/github-dialog-work/three"
git init --quiet "$TEST_ROOT/github-dialog-work/nested/four"
git -C "$TEST_ROOT/github-dialog-work/one" remote add origin git@github.example:alpha/one.git
git -C "$TEST_ROOT/github-dialog-work/one-copy" remote add origin git@github.example:alpha/one.git
git -C "$TEST_ROOT/github-dialog-work/two" remote add origin git@github.example:beta/two.git
git -C "$TEST_ROOT/github-dialog-work/three" remote add origin git@github.example:gamma/three.git
git -C "$TEST_ROOT/github-dialog-work/nested/four" remote add origin git@github.example:delta/four.git
git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf git@github.example:alpha/one.git
git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf git@github.example:beta/two.git
git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf git@github.example:gamma/three.git
git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf git@github.example:delta/four.git
github_dialog_config="$TEST_ROOT/github-dialog/config"
{
  printf '%s\n\n\n' "$TEST_ROOT/github-dialog-work"
  printf '%s\n' '-'
  printf 'author@example.test\n\n2021-01-01\ncommits,prs,issues\n'
  printf 'author@example.test\n\n2021-01-01\ncommits\n'
  printf '\nmirror@example.test\ngreens\nhttps://github.com/fixture/mirror\n%s\nmanual\n0\nn\n' "$TEST_ROOT/github-dialog-mirror"
} | CONTRIB_MIRROR_CONFIG="$github_dialog_config" bash "$ROOT/setup.sh" --in-root > "$TEST_ROOT/github-dialog-output" 2>&1 || {
  cat "$TEST_ROOT/github-dialog-output"; fail "multi-owner GitHub setup dialog";
}
if grep -qE 'separate GitHub accounts|Work GitHub org/owner name' "$TEST_ROOT/github-dialog-output"; then fail "new setup used a redundant global GitHub prompt"; fi
bash -c 'source "$1"; [[ "$SCAN_MODE" == in-root && "$SOURCE_COUNT" == 2 && "$SOURCE_1_ORGANIZATION" == beta && "$SOURCE_2_ORGANIZATION" == gamma ]]' bash "$github_dialog_config" || fail "setup did not skip and persist GitHub owners"
grep -q 'Skipping github github.example/alpha (1 repositories).' "$TEST_ROOT/github-dialog-output" || fail "setup did not report skipped source group"
grep -q 'Git author emails for github.example/alpha (comma-separated, or - to skip all 1 repositories)' "$TEST_ROOT/github-dialog-output" || fail "setup counted duplicate origin checkouts"
github_dialog_hash="$(git hash-object "$github_dialog_config")"
if printf 'y\n\n\n-\n-\n-\n-\n' | CONTRIB_MIRROR_CONFIG="$github_dialog_config" bash "$ROOT/setup.sh" --recursive > "$TEST_ROOT/all-skipped-output" 2>&1; then
  fail "setup accepted every source group being skipped"
fi
grep -q 'Every detected source group was skipped' "$TEST_ROOT/all-skipped-output" || fail "all-skipped setup error"
[[ "$(git hash-object "$github_dialog_config")" == "$github_dialog_hash" ]] || fail "all-skipped setup changed config"
mkdir -p "$TEST_ROOT/additional-work"
{
  printf 'y\n\n%s\n\n' "$TEST_ROOT/additional-work"
  printf '\n\n\n\n\n\n\n\n\n\n\n\nn\n'
} |
  CONTRIB_MIRROR_CONFIG="$dialog_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/dialog-defaults-output" 2>&1 || {
    cat "$TEST_ROOT/dialog-defaults-output"; fail "setup rerun with saved defaults";
  }
bash -c 'source "$1"; [[ "$SCAN_MODE" == in-root && "$WORK_DIRS" == "$2"$'"'"'\n'"'"'"$3" && "$SOURCE_1_USERNAME" == fixture && "$SOURCE_1_ACTIVITY_TYPES" == commits,mrs,issues && "$MIRROR_EMAIL" == mirror@example.test && "$SCHEDULER" == manual ]]' bash "$dialog_config" "$WORK_DIR" "$TEST_ROOT/additional-work" || fail "setup rerun did not retain and append work directories"
grep -q 'Daily hour (0-23, local timezone) \[11\]' "$TEST_ROOT/dialog-defaults-output" || fail "setup did not show the saved sync hour"
bash -c 'source "$1"; [[ "$SYNC_HOUR" == 11 ]]' bash "$dialog_config" || fail "setup did not retain the saved sync hour"
[[ "$(grep -c '^SYNC_HOUR=' "$dialog_config")" == 1 ]] || fail "setup did not remove stale sync-hour assignments"
{
  printf 'y\n\n'
  printf '\n\n\n\n\n\n\n\n\n\n\n\nn\n'
} |
  CONTRIB_MIRROR_CONFIG="$dialog_config" bash "$ROOT/setup.sh" --recursive > "$TEST_ROOT/dialog-recursive-output" 2>&1 || {
    cat "$TEST_ROOT/dialog-recursive-output"; fail "setup recursive mode switch";
  }
bash -c 'source "$1"; [[ "$SCAN_MODE" == recursive ]]' bash "$dialog_config" || fail "setup did not persist recursive mode"
CONTRIB_MIRROR_CONFIG="$dialog_config" bash "$ROOT/sync.sh" --status > "$TEST_ROOT/recursive-status"
grep -Fq "$WORK_DIR (1 repos)" "$TEST_ROOT/recursive-status" || fail "status did not deduplicate recursive checkouts"

# Work roots can be removed by repeatable CLI flags or the numbered rerun
# dialog; failed removals leave the original configuration untouched.
removal_config="$TEST_ROOT/removal-config"
cp "$dialog_config" "$removal_config"
mkdir -p "$TEST_ROOT/third-work"
WORK_DIRS="$WORK_DIR"$'\n'"$TEST_ROOT/additional-work"$'\n'"$TEST_ROOT/third-work"
greens_save_config "$removal_config" WORK_DIRS
{
  printf '\n\n\n\n\n\n\n\n\n\n\n\n'
  printf 'n\n'
} | CONTRIB_MIRROR_CONFIG="$removal_config" bash "$ROOT/setup.sh" \
    --remove-work-dir "$TEST_ROOT/additional-work" --remove-work-dir "$TEST_ROOT/third-work" > "$TEST_ROOT/removal-output" 2>&1 || {
  cat "$TEST_ROOT/removal-output"; fail "CLI work-directory removal";
}
bash -c 'source "$1"; [[ "$WORK_DIRS" == "$2" ]]' bash "$removal_config" "$WORK_DIR" || fail "CLI removal was not persisted"
removal_hash="$(git hash-object "$removal_config")"
if CONTRIB_MIRROR_CONFIG="$removal_config" bash "$ROOT/setup.sh" --remove-work-dir "$TEST_ROOT/not-configured" > "$TEST_ROOT/removal-invalid-output" 2>&1; then
  fail "unknown work-directory removal was accepted"
fi
[[ "$(git hash-object "$removal_config")" == "$removal_hash" ]] || fail "failed removal changed config"

unavailable_removal_config="$TEST_ROOT/unavailable-removal-config"
cp "$dialog_config" "$unavailable_removal_config"
WORK_DIRS="$WORK_DIR"$'\n'"$TEST_ROOT/additional-work"$'\n'"$TEST_ROOT/unavailable-work"
greens_save_config "$unavailable_removal_config" WORK_DIRS
unavailable_hash="$(git hash-object "$unavailable_removal_config")"
if printf '\n' | CONTRIB_MIRROR_CONFIG="$unavailable_removal_config" bash "$ROOT/setup.sh" \
    --remove-work-dir "$TEST_ROOT/additional-work" > "$TEST_ROOT/unavailable-removal-output" 2>&1; then
  fail "removal accepted an unavailable retained root"
fi
grep -q 'Retained work directory is unavailable during removal' "$TEST_ROOT/unavailable-removal-output" || fail "unavailable retained-root error"
[[ "$(git hash-object "$unavailable_removal_config")" == "$unavailable_hash" ]] || fail "unavailable retained root changed config"

last_root_config="$TEST_ROOT/last-root-config"
cp "$removal_config" "$last_root_config"
last_root_hash="$(git hash-object "$last_root_config")"
if printf '' | CONTRIB_MIRROR_CONFIG="$last_root_config" bash "$ROOT/setup.sh" \
    --remove-work-dir "$WORK_DIR" > "$TEST_ROOT/last-root-output" 2>&1; then
  fail "last work directory was removed without a replacement"
fi
[[ "$(git hash-object "$last_root_config")" == "$last_root_hash" ]] || fail "last-root failure changed config"

dialog_removal_config="$TEST_ROOT/dialog-removal-config"
cp "$dialog_config" "$dialog_removal_config"
{
  printf 'y\n2\n\n\n'
  printf '\n\n\n\n\n\n\n\n\n\n\n\n'
  printf 'n\n'
} | CONTRIB_MIRROR_CONFIG="$dialog_removal_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/dialog-removal-output" 2>&1 || {
  cat "$TEST_ROOT/dialog-removal-output"; fail "numbered work-directory removal";
}
bash -c 'source "$1"; [[ "$WORK_DIRS" == "$2" ]]' bash "$dialog_removal_config" "$WORK_DIR" || fail "numbered removal was not persisted"

# The existing privacy scrub must retain activity IDs, so a subsequent provider
# sync cannot recreate all previously mirrored contributions.
git -C "$MIRROR_DIR" remote set-url origin https://github.com/fixture/mirror
cat > "$MIRROR_DIR/README.md" <<'DASHBOARD'
# Work Contributions Mirror
## Overview
## Repository Breakdown
## Sync Info
Generated by [greens](https://github.com/yuvrajangadsingh/greens)
DASHBOARD
git -C "$MIRROR_DIR" add README.md
git -C "$MIRROR_DIR" commit --quiet -m 'Update sync status'
git -C "$MIRROR_DIR" push --quiet origin main
printf 'YES\n' | CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/sync.sh" --privacy-migrate > "$TEST_ROOT/migration-output" 2>&1 || {
  cat "$TEST_ROOT/migration-output"; fail "privacy migration";
}
[[ "$(git -C "$MIRROR_DIR" log --format=%B | grep -c '^Greens-Activity: ')" == 10 ]] || fail "migration lost IDs"
run_sync
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 10 ]] || fail "migration caused duplicate sync"
echo "PASS: retained MR commits and privacy migration preserve activity identities"

# Commit-only and legacy GitHub configurations still execute without glab calls.
for provider in git github; do
  git init --quiet "$TEST_ROOT/$provider-mirror"
  git -C "$TEST_ROOT/$provider-mirror" symbolic-ref HEAD refs/heads/main
  git init --bare --quiet "$TEST_ROOT/remotes/$provider-mirror.git"
  git -C "$TEST_ROOT/$provider-mirror" remote add origin "$TEST_ROOT/remotes/$provider-mirror.git"
  prefix=git@forge.example:team/
  expected_count=3
  if [[ "$provider" == github ]]; then
    # The legacy path resolves insteadOf URLs before applying its prefix.
    prefix="$TEST_ROOT/remotes/"
    expected_count=2
  fi
  SOURCE_PROVIDER="$provider" MIRROR_DIR="$TEST_ROOT/$provider-mirror" \
    CACHE_DIR="$TEST_ROOT/$provider-cache" REMOTE_PREFIX="$prefix" \
    ACTIVITY_TYPES=commits GITHUB_USERNAME="" FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$TEST_ROOT/$provider-mirror" rev-list --count HEAD)" == "$expected_count" ]] || fail "$provider regression"
done
echo "PASS: Git-only and legacy GitHub commit sync"

# A new indexed configuration can combine GitLab and GitHub Enterprise
# organizations, each with independent identity, date, and activity settings.
mkdir -p "$TEST_ROOT/work-github"
git init --bare --quiet "$TEST_ROOT/remotes/github-source.git"
git init --quiet "$TEST_ROOT/work-github/app"
git -C "$TEST_ROOT/work-github/app" remote add origin git@github.example:acme/app.git
GIT_AUTHOR_DATE='2021-02-03T12:30:00Z' GIT_COMMITTER_DATE='2021-02-03T12:30:00Z' \
  git -C "$TEST_ROOT/work-github/app" commit --quiet --allow-empty -m private
git config --global url."$TEST_ROOT/remotes/github-source.git".insteadOf git@github.example:acme/app.git
git -C "$TEST_ROOT/work-github/app" push --quiet origin HEAD:refs/heads/main
git init --bare --quiet "$TEST_ROOT/remotes/mixed-mirror.git"
git --git-dir="$TEST_ROOT/remotes/mixed-mirror.git" symbolic-ref HEAD refs/heads/main
git init --quiet "$TEST_ROOT/mixed-mirror"
git -C "$TEST_ROOT/mixed-mirror" symbolic-ref HEAD refs/heads/main
git -C "$TEST_ROOT/mixed-mirror" remote add origin "$TEST_ROOT/remotes/mixed-mirror.git"
legacy_config="$CONFIG_FILE"
CONFIG_FILE="$TEST_ROOT/mixed-config"
# Values are consumed by name in greens_save_config.
# shellcheck disable=SC2034
WORK_DIRS="$TEST_ROOT/work"$'\n'"$TEST_ROOT/work-github" SCAN_MODE=recursive SOURCE_COUNT=2 \
SOURCE_1_PROVIDER=gitlab SOURCE_1_REMOTE_HOSTS=forge.example SOURCE_1_API_HOST=forge.example SOURCE_1_ORGANIZATION=team SOURCE_1_USERNAME=fixture \
SOURCE_1_EMAILS=author@example.test SOURCE_1_SINCE=2021-01-01 SOURCE_1_ACTIVITY_TYPES=commits,mrs,issues,comments,approvals,merges,state_changes \
SOURCE_2_PROVIDER=github SOURCE_2_REMOTE_HOSTS=github.example SOURCE_2_API_HOST=github.example SOURCE_2_ORGANIZATION=acme SOURCE_2_USERNAME=fixture-gh \
SOURCE_2_EMAILS=author@example.test SOURCE_2_SINCE=2021-01-01 SOURCE_2_ACTIVITY_TYPES=commits,prs,issues
MIRROR_DIR="$TEST_ROOT/mixed-mirror" CACHE_DIR="$TEST_ROOT/mixed-cache" LOG_DIR="$TEST_ROOT/mixed-logs"
greens_save_config "$CONFIG_FILE" WORK_DIRS SCAN_MODE SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_REMOTE_HOSTS SOURCE_1_API_HOST SOURCE_1_ORGANIZATION SOURCE_1_USERNAME SOURCE_1_EMAILS SOURCE_1_SINCE SOURCE_1_ACTIVITY_TYPES SOURCE_2_PROVIDER SOURCE_2_REMOTE_HOSTS SOURCE_2_API_HOST SOURCE_2_ORGANIZATION SOURCE_2_USERNAME SOURCE_2_EMAILS SOURCE_2_SINCE SOURCE_2_ACTIVITY_TYPES MIRROR_DIR CACHE_DIR LOG_DIR MIRROR_EMAIL SINCE
source "$ROOT/lib/gitlab.sh"
SCAN_MODE=in-root
[[ "$(greens_mixed_discover_sources | wc -l | tr -d ' ')" == 2 ]] || fail "mixed discovery ignored in-root mode"
SCAN_MODE=recursive
[[ "$(greens_mixed_discover_sources | wc -l | tr -d ' ')" == 2 ]] || fail "mixed discovery did not deduplicate recursive checkouts"
printf 'personal-gh\n' > "$TEST_ROOT/github-example-active"
FIXTURE_VISIBILITY=PUBLIC run_sync
[[ "$(git -C "$MIRROR_DIR" log --format=%B | grep -c '^Greens-Activity: ')" == 13 ]] || { cat "$TEST_ROOT/output"; fail "mixed provider activity count"; }
[[ "$(cat "$TEST_ROOT/github-example-active")" == personal-gh ]] || fail "GitHub source sync did not restore the active personal account"
FIXTURE_VISIBILITY=PUBLIC run_sync
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 13 ]] || fail "mixed provider rerun duplicated activity"
echo "PASS: mixed GitLab and GitHub Enterprise sources"

# Local-only groups scan every local ref across duplicate checkouts without
# contacting Git or provider APIs, and deduplicate shared commits.
mkdir -p "$TEST_ROOT/local-work/one"
git init --quiet "$TEST_ROOT/local-work/one"
git -C "$TEST_ROOT/local-work/one" remote add origin git@gitlab.invalid:offline/repo.git
GIT_AUTHOR_DATE='2021-04-01T10:00:00Z' GIT_COMMITTER_DATE='2021-04-01T10:00:00Z' git -C "$TEST_ROOT/local-work/one" commit --quiet --allow-empty -m local-main
git -C "$TEST_ROOT/local-work/one" checkout --quiet -b feature
GIT_AUTHOR_DATE='2021-04-02T10:00:00Z' GIT_COMMITTER_DATE='2021-04-02T10:00:00Z' git -C "$TEST_ROOT/local-work/one" commit --quiet --allow-empty -m local-feature
git -C "$TEST_ROOT/local-work/one" checkout --quiet master
cp -a "$TEST_ROOT/local-work/one" "$TEST_ROOT/local-work/two"
git -C "$TEST_ROOT/local-work/two" checkout --quiet -b second-copy
GIT_AUTHOR_DATE='2021-04-03T10:00:00Z' GIT_COMMITTER_DATE='2021-04-03T10:00:00Z' git -C "$TEST_ROOT/local-work/two" commit --quiet --allow-empty -m local-copy-only
git init --bare --quiet "$TEST_ROOT/remotes/local-mirror.git"
git --git-dir="$TEST_ROOT/remotes/local-mirror.git" symbolic-ref HEAD refs/heads/main
git init --quiet "$TEST_ROOT/local-mirror"
git -C "$TEST_ROOT/local-mirror" symbolic-ref HEAD refs/heads/main
git -C "$TEST_ROOT/local-mirror" remote add origin "$TEST_ROOT/remotes/local-mirror.git"
# Values are consumed by name in greens_save_config.
# shellcheck disable=SC2034
CONFIG_FILE="$TEST_ROOT/local-config" WORK_DIRS="$TEST_ROOT/local-work" SCAN_MODE=in-root SOURCE_COUNT=1 \
SOURCE_1_PROVIDER=gitlab SOURCE_1_REMOTE_HOSTS=gitlab.invalid SOURCE_1_API_HOST=gitlab.invalid SOURCE_1_ORGANIZATION=offline SOURCE_1_USERNAME="" \
SOURCE_1_EMAILS=author@example.test SOURCE_1_SINCE=2021-01-01 SOURCE_1_ACTIVITY_TYPES=commits SOURCE_1_ACCESS_MODE=local \
MIRROR_DIR="$TEST_ROOT/local-mirror" CACHE_DIR="$TEST_ROOT/local-cache" LOG_DIR="$TEST_ROOT/local-logs"
greens_save_config "$CONFIG_FILE" WORK_DIRS SCAN_MODE SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_REMOTE_HOSTS SOURCE_1_API_HOST SOURCE_1_ORGANIZATION SOURCE_1_USERNAME SOURCE_1_EMAILS SOURCE_1_SINCE SOURCE_1_ACTIVITY_TYPES SOURCE_1_ACCESS_MODE MIRROR_DIR CACHE_DIR LOG_DIR MIRROR_EMAIL
touch "$TEST_ROOT/forbid-glab"
FIXTURE_VISIBILITY=PUBLIC run_sync
rm "$TEST_ROOT/forbid-glab"
[[ ! -e "$TEST_ROOT/glab-called" ]] || fail "local-only sync invoked glab"
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 3 ]] || { cat "$TEST_ROOT/output"; fail "local-only all-ref or duplicate-checkout collection"; }
[[ -z "$(find "$CACHE_DIR" -maxdepth 1 -name '*.git' -print -quit 2>/dev/null)" ]] || fail "local-only sync created a bare source cache"
[[ -z "$(git -C "$TEST_ROOT/local-work/one" status --porcelain)$(git -C "$TEST_ROOT/local-work/two" status --porcelain)" ]] || fail "local-only sync modified a checkout"
CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/sync.sh" --status > "$TEST_ROOT/local-status"
grep -q 'access=local' "$TEST_ROOT/local-status" || fail "status omitted local access mode"

# Invalid local activity is rejected before any provider call, and a local
# group with no remaining checkout reports a clear discovery failure.
SOURCE_1_ACTIVITY_TYPES=commits,mrs
greens_save_config "$CONFIG_FILE" SOURCE_1_ACTIVITY_TYPES
rm -f "$TEST_ROOT/glab-called"; touch "$TEST_ROOT/forbid-glab"
if run_sync; then fail "local-only source accepted provider activity"; fi
[[ ! -e "$TEST_ROOT/glab-called" ]] || fail "invalid local activity invoked glab"
grep -q 'local source 1 only supports ACTIVITY_TYPES=commits' "$TEST_ROOT/output" || fail "invalid local activity error"
SOURCE_1_ACTIVITY_TYPES=commits WORK_DIRS="$TEST_ROOT/missing-local-work"
greens_save_config "$CONFIG_FILE" SOURCE_1_ACTIVITY_TYPES WORK_DIRS
if run_sync; then fail "local-only source without a checkout was accepted"; fi
grep -q 'no matching checkout remains for local source gitlab.invalid/offline' "$TEST_ROOT/output" || fail "missing local checkout error"
rm "$TEST_ROOT/forbid-glab"
echo "PASS: local-only all-ref collection and duplicate checkout deduplication"

# Runtime fallback is never automatic outside a terminal and atomically saves
# both the access mode and commit-only activity selection after confirmation.
# Values are consumed by name in greens_save_config.
# shellcheck disable=SC2034
CONFIG_FILE="$TEST_ROOT/runtime-fallback-config" SOURCE_COUNT=1 \
SOURCE_1_PROVIDER=gitlab SOURCE_1_API_HOST=gitlab.invalid SOURCE_1_ORGANIZATION=offline \
SOURCE_1_ACCESS_MODE=remote SOURCE_1_ACTIVITY_TYPES=commits,mrs
greens_save_config "$CONFIG_FILE" SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_API_HOST SOURCE_1_ORGANIZATION SOURCE_1_ACCESS_MODE SOURCE_1_ACTIVITY_TYPES
fallback_hash="$(git hash-object "$CONFIG_FILE")"
log() { :; }
greens_is_interactive() { return 1; }
if greens_offer_local_fallback 1 test; then fail "noninteractive fallback changed source mode"; fi
[[ "$(git hash-object "$CONFIG_FILE")" == "$fallback_hash" ]] || fail "noninteractive fallback changed config"
greens_is_interactive() { return 0; }
printf 'y\n' | greens_offer_local_fallback 1 test
bash -c 'source "$1"; [[ "$SOURCE_1_ACCESS_MODE" == local && "$SOURCE_1_ACTIVITY_TYPES" == commits ]]' bash "$CONFIG_FILE" || fail "interactive fallback was not persisted"
echo "PASS: interactive and noninteractive local fallback behavior"

CONFIG_FILE="$legacy_config"
MIRROR_DIR="$TEST_ROOT/mirror" CACHE_DIR="$TEST_ROOT/cache" LOG_DIR="$TEST_ROOT/logs"

# Changing the selected author must not import a previous author's cached
# commits into a fresh destination using the same configuration.
git init --quiet "$TEST_ROOT/other-mirror"
git -C "$TEST_ROOT/other-mirror" symbolic-ref HEAD refs/heads/main
git init --bare --quiet "$TEST_ROOT/remotes/other-mirror.git"
git -C "$TEST_ROOT/other-mirror" remote add origin "$TEST_ROOT/remotes/other-mirror.git"
EMAILS=other@example.test MIRROR_DIR="$TEST_ROOT/other-mirror" run_sync
[[ "$(git -C "$TEST_ROOT/other-mirror" rev-list --count HEAD)" == 8 ]] || fail "cached author activity mixed"
echo "PASS: source actor cache isolation"

# Scheduler lifecycle with a fake user manager; no host scheduling is touched.
cat > "$TEST_ROOT/bin/systemctl" <<'MOCK'
#!/bin/bash
echo "$*" >> "$TEST_ROOT/systemctl-calls"
MOCK
chmod +x "$TEST_ROOT/bin/systemctl"
export XDG_CONFIG_HOME="$TEST_ROOT/xdg"
CONFIG_FILE="$TEST_ROOT/config with % and \$ characters"
printf '#!/bin/bash\nprintf "%%s" "$CONTRIB_MIRROR_CONFIG" > "$TEST_ROOT/runner-result"\n' > "$TEST_ROOT/fake script"
greens_install_systemd "$TEST_ROOT/fake script" 7
unit="$(greens_scheduler_id)"
grep -q '^Persistent=true$' "$XDG_CONFIG_HOME/systemd/user/$unit.timer" || fail "timer is not persistent"
grep -q '^OnCalendar=\*-\*-\* 07:00:00$' "$XDG_CONFIG_HOME/systemd/user/$unit.timer" || fail "timer hour"
bash "$(dirname "$CONFIG_FILE")/$unit-run"
[[ "$(cat "$TEST_ROOT/runner-result")" == "$CONFIG_FILE" ]] || fail "scheduled config escaping"
greens_systemd_remove
[[ ! -e "$XDG_CONFIG_HOME/systemd/user/$unit.timer" ]] || fail "timer removal"
echo "PASS: setup dialog, rerun defaults, configuration persistence, scheduler environment and lifecycle"
