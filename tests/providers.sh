#!/bin/bash
# Offline integration tests: real Git repositories, fixture GitLab API responses.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT HOME="$TEST_ROOT/home" GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TEST_ROOT/gitconfig"
mkdir -p "$HOME" "$TEST_ROOT/bin"
export PATH="$TEST_ROOT/bin:$PATH"
# Keep nested setup/sync invocations on the interpreter running this suite.
ln -s "$BASH" "$TEST_ROOT/bin/bash"
cat > "$TEST_ROOT/bin/crontab" <<'MOCK'
#!/bin/bash
case "$1" in
  -l) [[ -f "$TEST_ROOT/crontab" ]] && cat "$TEST_ROOT/crontab" ;;
  -) cat > "$TEST_ROOT/crontab.next"; mv "$TEST_ROOT/crontab.next" "$TEST_ROOT/crontab" ;;
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
[[ "$(greens_remote_identity 'ssh://git@forge.example:2222/group/sub/repo.git')" == forge.example:2222/group/sub/repo ]] || fail "SSH URL normalization"
[[ "$(greens_remote_identity 'https://forge.example/group/sub/repo')" == forge.example/group/sub/repo ]] || fail "HTTPS normalization"
[[ "$(greens_remote_identity 'git@forge.example:project.git')" == forge.example/project ]] || fail "single-component Git path"
if greens_remote_identity 'https://forge.example' >/dev/null; then fail "accepted a URL with no repository path"; fi
if greens_destination_identity 'https://github.com/fixture' >/dev/null; then fail "accepted a mirror without owner/repo"; fi

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
if [[ -f "$TEST_ROOT/project-checkpoint-fixture" ]]; then
  case "$4" in
    projects/team%2Fcheckpoint)
      if [[ -f "$TEST_ROOT/checkpoint-replacement" ]]; then echo '{"id":18,"merge_requests_enabled":false}'
      else echo '{"id":17,"merge_requests_enabled":false}'; fi; exit 0 ;;
    projects/1[78]/issues\?*)
      project="${4#projects/}"; project="${project%%/*}"
      if [[ "$4" == *"updated_after=$FIXTURE_SINCE_UTC"* ]]; then
        printf '[{"id":%s01,"iid":1,"author":{"id":42},"created_at":"2021-02-03T12:00:00Z"}]\n' "$project"
      else echo '[]'; fi; exit 0 ;;
    projects/1[78]/issues/1/discussions*)
      project="${4#projects/}"; project="${project%%/*}"
      printf '[{"notes":[{"id":%s02,"author":{"id":42},"system":false,"type":"DiscussionNote","created_at":"2021-02-03T12:00:00Z"}]}]\n' "$project"; exit 0 ;;
  esac
fi
if [[ -f "$TEST_ROOT/rename-fixture" ]]; then
  case "$4" in
    projects/team%2Fold|projects/team%2Fnew|projects/team%2Fthird) echo '{"id":7,"issues_enabled":false}'; exit 0 ;;
    projects/team%2Ffork)
      if [[ -f "$TEST_ROOT/recreated-project" ]]; then echo '{"id":9,"issues_enabled":false}'
      else echo '{"id":8,"issues_enabled":false}'; fi; exit 0 ;;
  esac
fi
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
if [[ -f "$TEST_ROOT/forbid-github-source-api" && "$1" == api && "${3:-}" == github.example ]]; then touch "$TEST_ROOT/github-source-api-called"; exit 99; fi
case "$*" in
  'auth switch '*) echo "$*" >> "$TEST_ROOT/forbidden-switches"; exit 99 ;;
  'auth token --hostname github.example --user '*) printf 'fixture-token-%s\n' "${*: -1}" ;;
  'auth token --hostname github.example') printf 'fixture-token-%s\n' "$(cat "$TEST_ROOT/github-example-active" 2>/dev/null || echo fixture-gh)" ;;
  'auth token --hostname github.com --user '*)
    echo "$*" >> "$TEST_ROOT/destination-token-requests"
    [[ ! -f "$TEST_ROOT/pat-only" && ! -f "$TEST_ROOT/destination-token-fails" ]] || exit 1
    printf 'fixture-token-%s\n' "${*: -1}" ;;
  'auth token --hostname github.com') [[ ! -f "$TEST_ROOT/expired-destination" ]] || exit 1; echo fixture-token-fixture ;;
  'api --hostname github.example user') printf '{"login":"%s"}\n' "${GH_TOKEN#fixture-token-}" ;;
  'api --hostname github.example user --jq .login') printf '%s\n' "${GH_TOKEN#fixture-token-}" ;;
  'api --hostname github.example / --jq .current_user_url') echo 'https://github.example/api/v3/user' ;;
  'api --hostname github.example repos/acme/app --jq .id') echo 701 ;;
  'api --hostname github.example repos/acme/old --jq .id'|'api --hostname github.example repos/AcMe/Old --jq .id'|'api --hostname github.example repos/acme/new --jq .id'|'api --hostname github.example repos/acme/third --jq .id') echo 801 ;;
  'api --hostname github.example repos/acme/fork --jq .id') echo 802 ;;
  api\ --hostname\ github.example\ *-X\ GET\ search/issues*)
    [[ "${GH_TOKEN:-}" == fixture-token-fixture-gh ]] || exit 1
    if [[ -f "$TEST_ROOT/github-rename-fixture" ]]; then echo '{"items":[]}'; exit 0; fi
    if [[ "$*" == *'type:issue'* ]]; then
      echo '{"items":[{"id":502,"created_at":"2021-02-03T14:00:00Z","repository_url":"https://github.example/api/v3/repos/acme/app"}]}'
    else
      echo '{"items":[{"id":501,"created_at":"2021-02-03T13:00:00Z","updated_at":"2021-02-03T13:00:00Z","repository_url":"https://github.example/api/v3/repos/acme/app"}]}'
    fi
    ;;
  'api user --jq .login'|'api --hostname github.com user --jq .login')
    [[ ! -f "$TEST_ROOT/expired-destination" || "${GH_TOKEN:-}" == fixture-token-fixture ]] || exit 1
    if [[ -f "$TEST_ROOT/destination-wrong-login" ]]; then echo wrong-user
    else echo fixture; fi ;;
  'api user/emails --jq '*|'api --hostname github.com user/emails --jq '*) echo mirror@example.test ;;
  'api --hostname github.com repos/fixture/mirror') echo '{"private":true,"default_branch":"main"}' ;;
  'api --hostname github.example users/'*' --jq .type') echo Organization ;;
  'auth status'*) exit 0 ;;
  'repo view '*' --json visibility -q .visibility')
    echo "$*" >> "$TEST_ROOT/visibility-calls"
    echo "${FIXTURE_VISIBILITY:-PRIVATE}" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/gh"
git config --global url."$TEST_ROOT/remotes/mirror.git".insteadOf https://github.com/fixture/mirror
dialog_config="$TEST_ROOT/dialog/config"
{
  printf '%s\n\nforge.example\nauthor@example.test\ncommits, mrs, issues, prs, commits\nfixture\n2021-01-01\n' "$WORK_DIR"
  printf 'fixture\nmirror@example.test\ngreens\n'
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
# First use into a config directory that doesn't exist yet: setup's job and
# the first sync must use the ID that later runs derive once it exists.
(
  cd "$TEST_ROOT"
  {
    printf '%s\n\nforge.example\nauthor@example.test\ncommits, mrs, issues, prs, commits\nfixture\n2021-01-01\n' "$WORK_DIR"
    printf 'fixture\nmirror@example.test\ngreens\n'
    printf 'https://github.com/fixture/mirror\n%s\ncron\n0\nn\n' "$TEST_ROOT/fresh-mirror"
  } | SCAN_MODE=in-root ACTIVITY_TYPES=commits,prs,issues CONTRIB_MIRROR_CONFIG=./fresh-profile/config bash "$ROOT/sync.sh" > "$TEST_ROOT/fresh-output" 2>&1 || {
    cat "$TEST_ROOT/fresh-output"; fail "first use into a new config directory";
  }
  CONFIG_FILE="$(greens_config_path ./fresh-profile/config)"
  crontab -l | grep -q "# $(greens_scheduler_id)$" || fail "setup installed its job under another ID: $(crontab -l)"
  [[ -f "$(LOG_DIR="$HOME/.contrib-mirror/logs" greens_stamp_path)" ]] || fail "first sync recorded success under another ID: $(ls "$HOME/.contrib-mirror/logs")"
  greens_remove_cron
)

# Older setup versions could leave an early default before the latest saved
# value. Loading must use the last assignment and the next save must clean it.
SYNC_HOUR=11 greens_save_config "$dialog_config" SYNC_HOUR
{ printf '%s\n' 'SYNC_HOUR="${SYNC_HOUR:-0}"'; cat "$dialog_config"; } > "$dialog_config.duplicate"
mv "$dialog_config.duplicate" "$dialog_config"

# An unreachable GitLab commit source can use local-only collection without
# attempting glab authentication.
mkdir -p "$TEST_ROOT/local-dialog-work/repo"
git init --quiet "$TEST_ROOT/local-dialog-work/repo"
git -C "$TEST_ROOT/local-dialog-work/repo" remote add origin git@gitlab.com:offline/repo.git
git config --global --add url."$TEST_ROOT/missing/offline.git".insteadOf git@gitlab.com:offline/repo.git
local_dialog_config="$TEST_ROOT/local-dialog/config"
touch "$TEST_ROOT/forbid-glab"
{
  printf '%s\n\nauthor@example.test\ncommits\ny\n2021-01-01\n' "$TEST_ROOT/local-dialog-work"
  printf '\n\n\nhttps://github.com/fixture/mirror\n%s\nmanual\n0\nn\n' "$TEST_ROOT/local-dialog-mirror"
} | CONTRIB_MIRROR_CONFIG="$local_dialog_config" bash "$ROOT/setup.sh" --in-root > "$TEST_ROOT/local-dialog-output" 2>&1 || {
  rm -f "$TEST_ROOT/forbid-glab"; cat "$TEST_ROOT/local-dialog-output"; fail "local-only setup dialog";
}
rm "$TEST_ROOT/forbid-glab"
[[ ! -e "$TEST_ROOT/glab-called" ]] || fail "local-only setup invoked glab"
bash -c 'source "$1"; [[ "$SOURCE_COUNT" == 1 && "$SOURCE_1_ACCESS_MODE" == local && "$SOURCE_1_ACTIVITY_TYPES" == commits && -z "$SOURCE_1_USERNAME" ]]' bash "$local_dialog_config" || fail "setup did not persist local-only source"
if grep -q 'GitLab username' "$TEST_ROOT/local-dialog-output"; then fail "local-only setup showed API account prompts"; fi

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
  printf 'author@example.test\ncommits,prs,issues\n\n2021-01-01\n'
  printf 'author@example.test\ncommits\n2021-01-01\n'
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
  git -C "$TEST_ROOT/$provider-mirror" remote add origin "https://github.com/fixture/$provider-mirror"
  git config --global url."$TEST_ROOT/remotes/$provider-mirror.git".insteadOf "https://github.com/fixture/$provider-mirror"
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
git -C "$TEST_ROOT/mixed-mirror" remote add origin https://github.com/fixture/mixed-mirror
git config --global url."$TEST_ROOT/remotes/mixed-mirror.git".insteadOf https://github.com/fixture/mixed-mirror
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
# GitHub search stops at 1,000 results, so a window reporting more is split in two.
(
  SOURCE_API_HOST=github.example SOURCE_USERNAME=fixture-gh SOURCE_ORGANIZATION=acme
  since_epoch=1609459200 run_epoch=1612137600
  # The month reports 1,500 results and its second half 150; the first half
  # has one. Each response holds one record, dated at its window's start.
  greens_gh_api_as() {
    local arg q from mode=one total=1
    for arg; do
      case "$arg" in q=*) q="${arg#q=}" ;; --paginate) mode=all ;; page=*) mode="$mode from ${arg#page=}" ;; esac
    done
    printf '%s %s\n' "$mode" "${q##*created:}" >> "$TEST_ROOT/split-queries"
    from="${q##*created:}"; from="${from%%..*}"
    [[ "$from" == *T*Z ]] || from=2021-01-10T00:00:00Z
    case "$q" in *2021-01-01T00:00:00Z..2021-02-01T00:00:00Z) total=1500 ;; *2021-01-16T12:00:01Z..*) total=150 ;; esac
    printf '{"total_count":%s,"items":[{"id":%s,"created_at":"%s","repository_url":"https://github.example/api/v3/repos/acme/app"}]}\n' \
      "$total" "${from//[!0-9]/}${mode//[!0-9]/}" "$from"
  }
  github_api_records prs "$TEST_ROOT/split" User > "$TEST_ROOT/split-records"
  # One page each for the month and its halves; only the 150-result half pages on from page 2.
  printf '%s\n' 'one 2021-01-01T00:00:00Z..2021-02-01T00:00:00Z' 'one 2021-01-01T00:00:00Z..2021-01-16T12:00:00Z' \
    'one 2021-01-16T12:00:01Z..2021-02-01T00:00:00Z' 'all from 2 2021-01-16T12:00:01Z..2021-02-01T00:00:00Z' > "$TEST_ROOT/split-expected"
  cmp -s "$TEST_ROOT/split-queries" "$TEST_ROOT/split-expected" || fail "search over 1,000 results was not split into adjacent windows: $(cat "$TEST_ROOT/split-queries")"
  [[ "$(jq -r .date "$TEST_ROOT/split-records" | tr '\n' '|')" == '2021-01-01 00:00:00 +0000|2021-01-16 12:00:01 +0000|2021-01-16 12:00:01 +0000|' ]] ||
    fail "split search lost records: $(cat "$TEST_ROOT/split-records")"
  # A search that timed out must fail, and say so on stderr, not in the records.
  greens_gh_api_as() { echo '{"total_count":5,"incomplete_results":true,"items":[]}'; }
  log() { printf '%s\n' "$*"; }
  if github_api_records prs "$TEST_ROOT/timeout" User > "$TEST_ROOT/timeout-out" 2> "$TEST_ROOT/timeout-err"; then fail "accepted a search that timed out"; fi
  { grep -q 'timed out' "$TEST_ROOT/timeout-err" && [[ ! -s "$TEST_ROOT/timeout-out" ]]; } || fail "search timeout was not reported on stderr"
)
printf 'personal-gh\n' > "$TEST_ROOT/github-example-active"
FIXTURE_VISIBILITY=PUBLIC run_sync
[[ "$(git -C "$MIRROR_DIR" log --format=%B | grep -c '^Greens-Activity: ')" == 13 ]] || { cat "$TEST_ROOT/output"; fail "mixed provider activity count"; }
[[ "$(cat "$TEST_ROOT/github-example-active")" == personal-gh ]] || fail "GitHub source sync did not restore the active personal account"
FIXTURE_VISIBILITY=PUBLIC run_sync
[[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 13 ]] || fail "mixed provider rerun duplicated activity"
echo "PASS: mixed GitLab and GitHub Enterprise sources"

# API-only groups keep syncing when their Git transport is unavailable.
(
  CONFIG_FILE="$TEST_ROOT/api-only-config" WORK_DIRS="$TEST_ROOT/api-only-work"
  MIRROR_DIR="$TEST_ROOT/api-only-mirror" CACHE_DIR="$TEST_ROOT/api-only-cache" LOG_DIR="$TEST_ROOT/api-only-logs"
  SOURCE_1_REMOTE_HOSTS=api-only-gitlab SOURCE_2_REMOTE_HOSTS=api-only-github
  SOURCE_1_ACTIVITY_TYPES=issues SOURCE_2_ACTIVITY_TYPES=issues
  MIRROR_URL=https://api-only@github.com/fixture/mirror
  mkdir -p "$WORK_DIRS"
  for provider in gitlab github; do
    git init --quiet "$WORK_DIRS/$provider"
    case "$provider" in gitlab) project=team/repo ;; github) project=acme/app ;; esac
    git -C "$WORK_DIRS/$provider" remote add origin "git@api-only-$provider:$project.git"
    git config --global --add url."$TEST_ROOT/nonexistent-source.git".insteadOf "git@api-only-$provider:"
  done
  git init --bare --quiet "$TEST_ROOT/remotes/api-only-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$MIRROR_URL"
  git config --global url."$TEST_ROOT/remotes/api-only-mirror.git".insteadOf "$MIRROR_URL"
  greens_save_config "$CONFIG_FILE" WORK_DIRS SCAN_MODE SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_REMOTE_HOSTS SOURCE_1_API_HOST SOURCE_1_ORGANIZATION SOURCE_1_USERNAME SOURCE_1_EMAILS SOURCE_1_SINCE SOURCE_1_ACTIVITY_TYPES SOURCE_2_PROVIDER SOURCE_2_REMOTE_HOSTS SOURCE_2_API_HOST SOURCE_2_ORGANIZATION SOURCE_2_USERNAME SOURCE_2_EMAILS SOURCE_2_SINCE SOURCE_2_ACTIVITY_TYPES MIRROR_DIR MIRROR_URL CACHE_DIR LOG_DIR MIRROR_EMAIL SINCE
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 2 ]] || fail "API-only activity was not mirrored"
  first_head="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$first_head" ]] || fail "API-only rerun duplicated activity"
  # Failure of API authentication must still abort instead of changing mode.
  touch "$TEST_ROOT/api-fails"
  if run_sync; then fail "API-only source bypassed API validation"; fi
  rm "$TEST_ROOT/api-fails"
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$first_head" ]] || fail "failed API validation added activity"
  bash -c 'source "$1"; [[ "$SOURCE_1_ACTIVITY_TYPES" == issues && "${SOURCE_1_ACCESS_MODE:-remote}" == remote ]]' bash "$CONFIG_FILE" || fail "API-only sync changed source mode"
  {
    printf 'y\n'
    printf '\n%.0s' {1..17}
    printf 'n\n'
  } | SCHEDULER=manual CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/setup.sh" > "$TEST_ROOT/api-only-setup-output" 2>&1 || {
    cat "$TEST_ROOT/api-only-setup-output"; fail "API-only setup probed unavailable Git transports";
  }
  bash -c 'source "$1"; [[ "$SOURCE_COUNT" == 2 && "$SOURCE_1_ACTIVITY_TYPES" == issues && "$SOURCE_2_ACTIVITY_TYPES" == issues && "$SOURCE_1_ACCESS_MODE" == remote && "$SOURCE_2_ACCESS_MODE" == remote ]]' bash "$CONFIG_FILE" || fail "API-only setup changed source activities/modes"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$first_head" ]] || fail "API-only setup rerun duplicated activity"
) || fail "API-only sources with unavailable Git transports"
echo "PASS: API-only GitLab/GitHub sync bypasses unavailable Git transports and retains API validation"

# Public GitHub origins are rewritten only for transport, so visibility still
# reaches gh and dashboard history must refuse to sync with exit code 3.
grep -q 'repo view fixture/mixed-mirror ' "$TEST_ROOT/visibility-calls" || fail "mixed mirror visibility was not queried"
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
public_head="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
public_checkpoints="$(cat "$CACHE_DIR"/activity-state/*/*.checkpoint)"
public_rc=0
FIXTURE_VISIBILITY=PUBLIC CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" FORCE=1 bash "$ROOT/sync.sh" > "$TEST_ROOT/public-refusal-output" 2>&1 || public_rc=$?
[[ "$public_rc" == 3 ]] || { cat "$TEST_ROOT/public-refusal-output"; fail "public dashboard history did not exit 3"; }
[[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$public_head" ]] || fail "public refusal changed mirror history"
[[ "$(cat "$CACHE_DIR"/activity-state/*/*.checkpoint)" == "$public_checkpoints" ]] || fail "public refusal advanced checkpoints"
echo "PASS: verified public mirror visibility and dashboard refusal"

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
git -C "$TEST_ROOT/local-mirror" remote add origin https://github.com/fixture/local-mirror
git config --global url."$TEST_ROOT/remotes/local-mirror.git".insteadOf https://github.com/fixture/local-mirror
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
if [[ "$*" == '--user show-environment' && -f "$TEST_ROOT/no-systemd-manager" ]]; then
  echo 'Failed to connect to bus' >&2; exit 1
fi
if [[ "$*" == '--user enable --now '* && -f "$TEST_ROOT/systemd-install-fails" ]]; then exit 1; fi
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

# Saved URLs remain usable as defaults, but their credentials never appear in
# summaries or prompts. Rerunning an indexed migration preserves legacy mode.
masked_config="$TEST_ROOT/masked-config"
cp "$dialog_config" "$masked_config"
# Values are consumed by name in greens_save_config.
# shellcheck disable=SC2034
MIRROR_URL=https://fixture-secret@github.com/fixture/mirror GREENS_LEGACY_TIMESTAMPS=1
greens_save_config "$masked_config" MIRROR_URL GREENS_LEGACY_TIMESTAMPS
touch "$TEST_ROOT/pat-only"
rm -f "$TEST_ROOT/destination-switches"
{
  printf 'y\n'
  printf '\n%.0s' {1..14}
  printf 'n\n'
} | GH_TOKEN=fixture-token-fixture GH_HOST=github.example CONTRIB_MIRROR_CONFIG="$masked_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/masked-output" 2>&1 || {
  cat "$TEST_ROOT/masked-output"; fail "PAT-only setup with saved credentials";
}
rm "$TEST_ROOT/pat-only"
[[ ! -e "$TEST_ROOT/destination-switches" ]] || fail "PAT-only setup switched an already active destination account"
if grep -q fixture-secret "$TEST_ROOT/masked-output"; then fail "setup exposed mirror credentials"; fi
grep -Fq 'Mirror: https://****@github.com/fixture/mirror' "$TEST_ROOT/masked-output" || fail "summary did not mask credentials"
grep -Fq 'GitHub mirror URL [https://****@github.com/fixture/mirror]' "$TEST_ROOT/masked-output" || fail "prompt did not mask credentials"
bash -c 'source "$1"; [[ "$MIRROR_URL" == https://fixture-secret@github.com/fixture/mirror && "$GREENS_LEGACY_TIMESTAMPS" == 1 ]]' bash "$masked_config" || fail "setup lost saved URL or legacy timestamp mode"

# A reachable SSH GitLab source can collect remote commits without any API
# authentication. Git transport access is represented by a local bare fixture.
mkdir -p "$TEST_ROOT/ssh-only-work/repo"
git init --quiet "$TEST_ROOT/ssh-only-work/repo"
git -C "$TEST_ROOT/ssh-only-work/repo" remote add origin git@gitlab.com:ssh-only/repo.git
git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf git@gitlab.com:ssh-only/repo.git
touch "$TEST_ROOT/forbid-glab"
rm -f "$TEST_ROOT/glab-called"
{
  printf '%s\n\nauthor@example.test\ncommits\n2021-01-01\n' "$TEST_ROOT/ssh-only-work"
  printf '\n\n\nhttps://github.com/fixture/mirror\n%s\nmanual\n0\nn\n' "$TEST_ROOT/ssh-only-mirror"
} | CONTRIB_MIRROR_CONFIG="$TEST_ROOT/ssh-only-config" bash "$ROOT/setup.sh" --in-root > "$TEST_ROOT/ssh-only-output" 2>&1 || {
  cat "$TEST_ROOT/ssh-only-output"; fail "SSH-only commit setup";
}
rm "$TEST_ROOT/forbid-glab"
[[ ! -e "$TEST_ROOT/glab-called" ]] || fail "SSH-only setup invoked GitLab API"
bash -c 'source "$1"; [[ "$SOURCE_1_ACCESS_MODE" == remote && "$SOURCE_1_ACTIVITY_TYPES" == commits ]]' bash "$TEST_ROOT/ssh-only-config" || fail "SSH-only setup lost remote history mode"
echo "PASS: credential masking, PAT-only destination, legacy rerun, and SSH-only sources"

# Reset removes this configuration's launchd label and the legacy agent while
# preserving a different configuration's agent. Also cover an unloaded plist.
cat > "$TEST_ROOT/bin/launchctl" <<'MOCK'
#!/bin/bash
case "$1" in
  list) exit 1 ;;
  bootout) printf '%s\n' "$2" >> "$TEST_ROOT/launchctl-calls" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/launchctl"
CONFIG_FILE="$TEST_ROOT/reset-config"
printf '# reset fixture\n' > "$CONFIG_FILE"
label="$(greens_launchd_label)"
mkdir -p "$HOME/Library/LaunchAgents"
touch "$HOME/Library/LaunchAgents/$label.plist" "$HOME/Library/LaunchAgents/com.greens.plist" "$HOME/Library/LaunchAgents/com.greens.other.plist"
printf 'y\ny\nn\nn\nn\nn\nn\n' | CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/sync.sh" --reset > "$TEST_ROOT/reset-output" 2>&1 || {
  cat "$TEST_ROOT/reset-output"; fail "launchd reset";
}
[[ ! -e "$HOME/Library/LaunchAgents/$label.plist" && ! -e "$HOME/Library/LaunchAgents/com.greens.plist" ]] || fail "reset left a launchd plist"
[[ -f "$HOME/Library/LaunchAgents/com.greens.other.plist" ]] || fail "reset removed another configuration's launchd agent"
grep -qx "gui/$(id -u)/$label" "$TEST_ROOT/launchctl-calls" || fail "reset did not boot out scoped launchd label"
grep -qx "gui/$(id -u)/com.greens" "$TEST_ROOT/launchctl-calls" || fail "reset did not boot out legacy launchd label"
echo "PASS: scoped and legacy launchd reset"

# Exercise preflight with real terminal descriptors. Prompts must read stdin,
# while repository rows use their own descriptor throughout the loop.
cat > "$TEST_ROOT/terminal-preflight" <<'FIXTURE'
set -euo pipefail
source "$1/lib/common.sh"
source "$1/lib/gitlab.sh"
CONFIG_FILE="$TEST_ROOT/terminal-config"
RUN_TMP="$TEST_ROOT"
SOURCE_COUNT=2
SOURCE_1_PROVIDER=gitlab SOURCE_1_API_HOST=offline.test SOURCE_1_ORGANIZATION=one SOURCE_1_ACCESS_MODE=remote SOURCE_1_ACTIVITY_TYPES=commits
SOURCE_2_PROVIDER=gitlab SOURCE_2_API_HOST=offline.test SOURCE_2_ORGANIZATION=two SOURCE_2_ACCESS_MODE=remote SOURCE_2_ACTIVITY_TYPES=commits
greens_save_config "$CONFIG_FILE" SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_API_HOST SOURCE_1_ORGANIZATION SOURCE_1_ACCESS_MODE SOURCE_1_ACTIVITY_TYPES SOURCE_2_PROVIDER SOURCE_2_API_HOST SOURCE_2_ORGANIZATION SOURCE_2_ACCESS_MODE SOURCE_2_ACTIVITY_TYPES
printf '1\toffline.test/one/repo\tmissing-one\n2\toffline.test/two/repo\tmissing-two\n' > "$TEST_ROOT/terminal-sources"
log() { printf '%s\n' "$*"; }
greens_run() { return 1; }
greens_preflight_mixed_sources "$TEST_ROOT/terminal-sources"
[[ "$SOURCE_1_ACCESS_MODE" == local && "$SOURCE_2_ACCESS_MODE" == local ]]
echo TERMINAL_PREFLIGHT_PASSED
FIXTURE
python3 "$ROOT/tests/terminal-preflight.py" "$TEST_ROOT/terminal-preflight" "$ROOT"
echo "PASS: terminal preflight fallback reads confirmations for every source"

# A migrated mirror retains timestamp deduplication only for legacy commits.
# Distinct IDs discovered on separate runs may legitimately share an epoch.
(
  MIRROR_DIR="$TEST_ROOT/legacy-epoch-mirror" MIRROR_EMAIL=mirror@example.test MIRROR_NAME=greens
  RUN_TMP="$TEST_ROOT/legacy-epoch-run" SUCCESS_STAMP_FILE="$TEST_ROOT/legacy-epoch-stamp"
  GREENS_LEGACY_TIMESTAMPS=1
  mkdir -p "$RUN_TMP"
  git init --bare --quiet "$TEST_ROOT/remotes/legacy-epoch-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$TEST_ROOT/remotes/legacy-epoch-mirror.git"
  # Initialization/status epochs are not activities, even with the current
  # mirror email. The legacy sync used an email that has since changed.
  GIT_AUTHOR_DATE=2021-01-01T10:00:00Z GIT_COMMITTER_DATE=2021-01-01T10:00:00Z \
    git -C "$MIRROR_DIR" -c user.email="$MIRROR_EMAIL" commit --quiet --allow-empty -m init
  init_epoch="$(git -C "$MIRROR_DIR" log -1 --format=%at)"
  GIT_AUTHOR_DATE=2021-01-01T12:00:00Z GIT_COMMITTER_DATE=2021-01-01T12:00:00Z \
    git -C "$MIRROR_DIR" -c user.email=previous-mirror@example.test commit --quiet --allow-empty -m sync
  mirror_visibility() { echo public; }
  : > "$RUN_TMP/publish"
  legacy_epoch="$(git -C "$MIRROR_DIR" log -1 --format=%at)"
  printf '# generated status fixture\n' > "$MIRROR_DIR/README.md"
  git -C "$MIRROR_DIR" add README.md
  GIT_AUTHOR_DATE=2021-01-02T12:00:00Z GIT_COMMITTER_DATE=2021-01-02T12:00:00Z \
    git -C "$MIRROR_DIR" -c user.email="$MIRROR_EMAIL" commit --quiet -m 'Update sync status'
  status_epoch="$(git -C "$MIRROR_DIR" log -1 --format=%at)"
  # Copied messages may even match the status subject; an unchanged README
  # tree makes this an activity rather than a generated status commit.
  GIT_AUTHOR_DATE=2021-01-03T12:00:00Z GIT_COMMITTER_DATE=2021-01-03T12:00:00Z \
    git -C "$MIRROR_DIR" -c user.email="$MIRROR_EMAIL" commit --quiet --allow-empty -m 'Update sync status'
  copied_epoch="$(git -C "$MIRROR_DIR" log -1 --format=%at)"
  new_epoch=1612353600 # 2021-02-03T12:00:00Z, independent of the test host timezone.
  jq -nc --argjson legacy "$legacy_epoch" --argjson epoch "$new_epoch" \
    --argjson init "$init_epoch" --argjson status "$status_epoch" --argjson copied "$copied_epoch" '
    {key:"legacy",epoch:$legacy,date:"2021-01-01T12:00:00Z",kind:"commits",project:"one"},
    {key:"init-coincidence",epoch:$init,date:"2021-01-01T10:00:00Z",kind:"commits",project:"one"},
    {key:"status-coincidence",epoch:$status,date:"2021-01-02T12:00:00Z",kind:"commits",project:"one"},
    {key:"copied",epoch:$copied,date:"2021-01-03T12:00:00Z",kind:"commits",project:"one"},
    {key:"first",epoch:$epoch,date:"2021-02-03T12:00:00Z",kind:"commits",project:"one"}' > "$RUN_TMP/input"
  greens_mirror_mixed_records "$RUN_TMP/input" "$RUN_TMP/publish" > "$TEST_ROOT/legacy-epoch-output" 2>&1
  [[ "$(git -C "$MIRROR_DIR" log --format=%at --author='<previous-mirror@example.test>')" == "$legacy_epoch" ]] || fail "legacy attribution changed"
  [[ "$(git -C "$MIRROR_DIR" log --format=%at | grep -cx "$legacy_epoch")" == 1 ]] || fail "legacy timestamp was duplicated after changing mirror email"
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 7 ]] || fail "legacy/metadata timestamps were misclassified"
  jq -nc --argjson epoch "$new_epoch" '{key:"second",epoch:$epoch,date:"2021-02-03T12:00:00Z",kind:"commits",project:"two"}' >> "$RUN_TMP/input"
  greens_mirror_mixed_records "$RUN_TMP/input" "$RUN_TMP/publish" >> "$TEST_ROOT/legacy-epoch-output" 2>&1
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 8 ]] || fail "new activity at a marked commit timestamp was skipped"
  [[ "$(cat "$RUN_TMP/legacy-epochs")" == "$legacy_epoch"$'\n'"$copied_epoch" ]] || fail "legacy baseline lost copied activity or included metadata/marked commits"
  mirrored_head="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  greens_mirror_mixed_records "$RUN_TMP/input" "$RUN_TMP/publish" >> "$TEST_ROOT/legacy-epoch-output" 2>&1
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$mirrored_head" ]] || fail "legacy-mode rerun duplicated activity IDs"
)
echo "PASS: legacy timestamps survive mirror email changes and exclude metadata/marked activities"

# The following configs each have one remote commit-only source and one root:
# accept saved defaults, then decline the initial sync.
rerun_setup_defaults() {
  {
    printf 'y\n'
    printf '\n%.0s' {1..12}
    printf 'n\n'
  } | CONTRIB_MIRROR_CONFIG="$1" bash "$ROOT/setup.sh" > "$2" 2>&1
}

# An expired active work account must not prevent selecting the saved personal
# account. Failed switches and wrong actors still leave the config untouched.
expired_config="$TEST_ROOT/expired-account-config"
cp "$TEST_ROOT/ssh-only-config" "$expired_config"
rm -f "$TEST_ROOT/destination-active" "$TEST_ROOT/destination-switches" "$TEST_ROOT/destination-token-requests"
touch "$TEST_ROOT/expired-destination"
rerun_setup_defaults "$expired_config" "$TEST_ROOT/expired-account-output" || {
  cat "$TEST_ROOT/expired-account-output"; fail "expired active account blocked saved personal account";
}
grep -qx 'auth token --hostname github.com --user fixture' "$TEST_ROOT/destination-token-requests" || fail "setup did not obtain saved personal credentials"
expired_hash="$(git hash-object "$expired_config")"
for failure in destination-token-fails destination-wrong-login; do
  rm -f "$TEST_ROOT/destination-active"
  touch "$TEST_ROOT/$failure"
  if GH_TOKEN='' GITHUB_TOKEN='' rerun_setup_defaults "$expired_config" "$TEST_ROOT/$failure-output"; then fail "setup accepted $failure"; fi
  [[ "$(git hash-object "$expired_config")" == "$expired_hash" ]] || fail "failed destination authentication changed config"
  rm "$TEST_ROOT/$failure"
done
rm -f "$TEST_ROOT/expired-destination" "$TEST_ROOT/destination-active"
echo "PASS: expired active account recovery and destination identity checks"

# One group remains visible while its second root is offline. Keep both host
# aliases, then prove discovery includes the returned alias after remounting.
alias_config="$TEST_ROOT/alias-config"
cp "$TEST_ROOT/ssh-only-config" "$alias_config"
mkdir -p "$TEST_ROOT/alias-work/repo"
git init --quiet "$TEST_ROOT/alias-work/repo"
git -C "$TEST_ROOT/alias-work/repo" remote add origin git@gitlab-work:ssh-only/other.git
bash -c 'source "$1/lib/common.sh"; source "$2"; WORK_DIRS="$WORK_DIRS"$'"'"'\n'"'"'"$3"; SOURCE_1_REMOTE_HOSTS=gitlab.com,gitlab-work; greens_save_config "$2" WORK_DIRS SOURCE_1_REMOTE_HOSTS' bash "$ROOT" "$alias_config" "$TEST_ROOT/alias-work"
mv "$TEST_ROOT/alias-work" "$TEST_ROOT/alias-work-offline"
{
  printf 'y\n'
  printf '\n%.0s' {1..12}
  printf 'n\n'
} | CONTRIB_MIRROR_CONFIG="$alias_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/alias-output" 2>&1 || {
  cat "$TEST_ROOT/alias-output"; fail "partially discovered source setup";
}
bash -c 'source "$1"; [[ "$SOURCE_1_REMOTE_HOSTS" == gitlab.com,gitlab-work ]]' bash "$alias_config" || fail "setup dropped or duplicated saved aliases"
mv "$TEST_ROOT/alias-work-offline" "$TEST_ROOT/alias-work"
bash -c 'source "$1/lib/common.sh"; source "$1/lib/gitlab.sh"; source "$2"; CACHE_DIR="$TEST_ROOT/unused-cache"; greens_mixed_discover_checkouts' bash "$ROOT" "$alias_config" > "$TEST_ROOT/alias-checkouts"
[[ "$(wc -l < "$TEST_ROOT/alias-checkouts" | tr -d ' ')" == 2 ]] || fail "returned alias checkout was not discovered"
grep -q 'gitlab.com/ssh-only/other' "$TEST_ROOT/alias-checkouts" || fail "returned alias was not mapped to saved API host"
echo "PASS: saved aliases survive partial discovery and a returning work root"

# Replacing the default configuration's schedule retires unscoped v1.8.2
# jobs. Custom configs and unrelated cron entries must remain independent.
mkdir -p "$HOME/.contrib-mirror" "$HOME/Library/LaunchAgents"
default_config="$HOME/.contrib-mirror/config"
cp "$TEST_ROOT/ssh-only-config" "$default_config"
legacy_cron="0 0 * * * /bin/bash $ROOT/sync.sh >> $HOME/.contrib-mirror/logs/sync.log 2>&1"
printf '%s\n' "$legacy_cron" \
  "0 2 * * * /bin/bash $TEST_ROOT/Cellar/greens/1.8.2/libexec/sync.sh >> $HOME/.contrib-mirror/logs/sync.log 2>&1" \
  "0 3 * * * /bin/bash $ROOT/other-sync.sh >> $HOME/other.log 2>&1" \
  "0 4 * * * CONTRIB_MIRROR_CONFIG=$expired_config /bin/bash $ROOT/sync.sh >> $HOME/other.log 2>&1 # greens-other" \
  "0 5 * * * /bin/bash $ROOT/sync.sh --status >> $HOME/status.log 2>&1" > "$TEST_ROOT/crontab"
cp "$TEST_ROOT/crontab" "$TEST_ROOT/legacy-crontab"
touch "$HOME/Library/LaunchAgents/com.greens.plist"
rerun_setup_defaults "$expired_config" "$TEST_ROOT/custom-scheduler-output" || {
  cat "$TEST_ROOT/custom-scheduler-output"; fail "custom-config scheduler rerun";
}
cmp -s "$TEST_ROOT/crontab" "$TEST_ROOT/legacy-crontab" || fail "custom setup removed a default or unrelated cron job"
[[ -f "$HOME/Library/LaunchAgents/com.greens.plist" ]] || fail "custom setup removed default legacy launchd agent"
rm -f "$TEST_ROOT/launchctl-calls"
cp "$default_config" "$TEST_ROOT/before-scheduler-config"
for failure in no-systemd-manager systemd-install-fails; do
  touch "$TEST_ROOT/$failure"
  if SCHEDULER=systemd rerun_setup_defaults "$default_config" "$TEST_ROOT/$failure-output"; then
    fail "setup accepted unavailable/failed systemd scheduling"
  fi
  rm "$TEST_ROOT/$failure"
  cmp -s "$TEST_ROOT/crontab" "$TEST_ROOT/legacy-crontab" || fail "failed replacement removed the working cron job"
  [[ -f "$HOME/Library/LaunchAgents/com.greens.plist" ]] || fail "failed replacement removed legacy launchd job"
  if [[ "$failure" == no-systemd-manager ]]; then
    cmp -s "$default_config" "$TEST_ROOT/before-scheduler-config" || fail "unavailable scheduler changed configuration"
    # macOS setup never offers systemd, so it rejects the saved value before checking the manager.
    diagnostic='systemd user manager is unavailable'
    [[ "$(uname -s)" == Linux ]] || diagnostic='Choose launchd, cron, or manual'
    grep -q "$diagnostic" "$TEST_ROOT/$failure-output" || fail "missing scheduler diagnostic"
  fi
  cp "$TEST_ROOT/before-scheduler-config" "$default_config"
done
SCHEDULER=cron SYNC_HOUR=9 rerun_setup_defaults "$default_config" "$TEST_ROOT/legacy-scheduler-output" || {
  cat "$TEST_ROOT/legacy-scheduler-output"; fail "legacy scheduler replacement";
}
[[ ! -e "$HOME/Library/LaunchAgents/com.greens.plist" ]] || fail "setup retained legacy launchd agent"
if grep -q "Cellar/greens/1.8.2" "$TEST_ROOT/crontab"; then fail "setup retained versioned legacy cron path"; fi
if grep -qxF "$legacy_cron" "$TEST_ROOT/crontab"; then fail "setup retained legacy cron hour"; fi
[[ "$(wc -l < "$TEST_ROOT/crontab" | tr -d ' ')" == 4 ]] || fail "scheduler replacement removed unrelated cron entries"
grep -q '^0 9 .*# greens-' "$TEST_ROOT/crontab" || fail "replacement cron schedule did not use new hour"
grep -qx "gui/$(id -u)/com.greens" "$TEST_ROOT/launchctl-calls" || fail "setup did not boot out legacy agent"
printf '%s\n' "$legacy_cron" >> "$TEST_ROOT/crontab"
SCHEDULER=manual rerun_setup_defaults "$default_config" "$TEST_ROOT/manual-scheduler-output" || {
  cat "$TEST_ROOT/manual-scheduler-output"; fail "legacy scheduler removal for manual sync";
}
[[ "$(wc -l < "$TEST_ROOT/crontab" | tr -d ' ')" == 3 ]] || fail "manual schedule retained old or scoped cron jobs"
if grep -qxF "$legacy_cron" "$TEST_ROOT/crontab"; then fail "manual setup retained legacy cron"; fi
echo "PASS: legacy scheduler migration, custom-config isolation, and manual cleanup"

# Existing personal SSH aliases are identities on github.com, while Git keeps
# the original alias URL (and therefore the user's SSH key selection).
cat > "$TEST_ROOT/bin/ssh" <<'MOCK'
#!/bin/bash
case "$*" in
  '-G -- github-personal'|'-G github-com') echo 'hostname github.com' ;;
  '-G -- not-github') echo 'hostname other.example' ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/ssh"
destination_alias_config="$TEST_ROOT/destination-alias-config"
cp "$TEST_ROOT/ssh-only-config" "$destination_alias_config"
cp -R "$TEST_ROOT/ssh-only-mirror" "$TEST_ROOT/destination-alias-mirror"
destination_alias=git@github-personal:fixture/mirror.git
git -C "$TEST_ROOT/destination-alias-mirror" remote set-url origin "$destination_alias"
git config --global url."$TEST_ROOT/remotes/mirror.git".insteadOf "$destination_alias"
bash -c 'source "$1/lib/common.sh"; source "$2"; MIRROR_URL="$3"; MIRROR_DIR="$4"; greens_save_config "$2" MIRROR_URL MIRROR_DIR' bash "$ROOT" "$destination_alias_config" "$destination_alias" "$TEST_ROOT/destination-alias-mirror"
rerun_setup_defaults "$destination_alias_config" "$TEST_ROOT/destination-alias-output" || {
  cat "$TEST_ROOT/destination-alias-output"; fail "SSH alias destination migration";
}
[[ "$(git -C "$TEST_ROOT/destination-alias-mirror" config remote.origin.url)" == "$destination_alias" ]] || fail "setup rewrote SSH transport alias"
bash -c 'source "$1"; [[ "$MIRROR_URL" == "$2" ]]' bash "$destination_alias_config" "$destination_alias" || fail "setup lost saved alias URL"
FORCE=1 CONTRIB_MIRROR_CONFIG="$destination_alias_config" bash "$ROOT/sync.sh" > "$TEST_ROOT/destination-alias-sync-output" 2>&1 || {
  cat "$TEST_ROOT/destination-alias-sync-output"; fail "SSH alias mirror sync";
}
if greens_destination_identity git@not-github:fixture/mirror.git >/dev/null; then fail "non-GitHub SSH alias accepted"; fi
echo "PASS: SSH mirror alias migration, transport preservation, and sync"

# Accepting defaults preserves an existing alias, even if the saved URL uses
# another transport. An explicitly entered replacement must repair origin.
bash -c 'source "$1/lib/common.sh"; MIRROR_URL=https://github.com/fixture/mirror; greens_save_config "$2" MIRROR_URL' bash "$ROOT" "$destination_alias_config"
rerun_setup_defaults "$destination_alias_config" "$TEST_ROOT/alias-default-output" || fail "default mirror URL rerun"
[[ "$(git -C "$TEST_ROOT/destination-alias-mirror" config remote.origin.url)" == "$destination_alias" ]] || fail "accepting defaults overwrote existing alias"
expired_url=https://fixture:expired-password@github.com/fixture/mirror
replacement_url=https://fixture:replacement-password@github.com/fixture/mirror
git -C "$TEST_ROOT/destination-alias-mirror" remote set-url origin "$expired_url"
git config --global url."$TEST_ROOT/nonexistent-mirror.git".insteadOf "$expired_url"
git config --global url."$TEST_ROOT/remotes/mirror.git".insteadOf "$replacement_url"
mirror_transport_answers() {
  printf 'y\n'
  printf '\n%.0s' {1..8}
  printf '%s\n\n\n\ny\n' "$replacement_url"
}
chmod 644 "$TEST_ROOT/destination-alias-mirror/.git/config"
mkdir -p "$TEST_ROOT/deny-config-chmod"
export FIXTURE_CHMOD
FIXTURE_CHMOD="$(command -v chmod)"
cat > "$TEST_ROOT/deny-config-chmod/chmod" <<'MOCK'
#!/bin/bash
if [[ "$1" == 600 && "$2" == "$TEST_ROOT/destination-alias-mirror/.git/config" ]]; then exit 1; fi
exec "$FIXTURE_CHMOD" "$@"
MOCK
chmod +x "$TEST_ROOT/deny-config-chmod/chmod"
if mirror_transport_answers | PATH="$TEST_ROOT/deny-config-chmod:$PATH" CONTRIB_MIRROR_CONFIG="$destination_alias_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/mirror-permission-failure" 2>&1; then
  fail "setup stored URL credentials despite failed config protection"
fi
grep -q 'Cannot secure the mirror Git config' "$TEST_ROOT/mirror-permission-failure" || fail "missing permission failure diagnostic"
[[ "$(git -C "$TEST_ROOT/destination-alias-mirror" config remote.origin.url)" == "$expired_url" ]] || fail "failed config protection changed origin"
mirror_transport_answers | CONTRIB_MIRROR_CONFIG="$destination_alias_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/mirror-url-edit-output" 2>&1 || {
  cat "$TEST_ROOT/mirror-url-edit-output"; fail "explicit mirror transport edit";
}
[[ "$(git -C "$TEST_ROOT/destination-alias-mirror" config remote.origin.url)" == "$replacement_url" ]] || fail "explicit mirror URL did not update origin"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;; # Windows ACLs do not implement these POSIX mode bits.
  *) python3 -c 'import os,stat,sys; assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode)==0o600' "$TEST_ROOT/destination-alias-mirror/.git/config" || fail "replacement URL credentials remained readable by other users" ;;
esac
if grep -q 'Initial sync failed' "$TEST_ROOT/mirror-url-edit-output"; then cat "$TEST_ROOT/mirror-url-edit-output"; fail "initial sync used expired mirror URL"; fi
FORCE=1 CONTRIB_MIRROR_CONFIG="$destination_alias_config" bash "$ROOT/sync.sh" > "$TEST_ROOT/mirror-url-fresh-output" 2>&1 || {
  cat "$TEST_ROOT/mirror-url-fresh-output"; fail "fresh sync lost replacement mirror URL";
}
echo "PASS: explicit mirror transport replacement repairs initial and fresh sync while defaults retain aliases"

# Local insteadOf rules belong to each source checkout. Cached collection must
# retain their transports while provider identity/grouping uses the raw origin.
(
  CONFIG_FILE="$TEST_ROOT/checkout-rewrite-config" WORK_DIRS="$TEST_ROOT/checkout-rewrite-work" SCAN_MODE=in-root SOURCE_COUNT=2
  MIRROR_DIR="$TEST_ROOT/checkout-rewrite-mirror" MIRROR_URL=https://checkout-rewrite@github.com/fixture/mirror
  CACHE_DIR="$TEST_ROOT/checkout-rewrite-cache" LOG_DIR="$TEST_ROOT/checkout-rewrite-logs" MIRROR_EMAIL=mirror@example.test
  # Values are consumed by name in greens_save_config and indexed accessors.
  # shellcheck disable=SC2034
  SOURCE_1_PROVIDER=gitlab SOURCE_1_REMOTE_HOSTS=checkout-gitlab SOURCE_1_API_HOST=forge.example SOURCE_1_ORGANIZATION=team SOURCE_1_USERNAME=fixture
  SOURCE_2_PROVIDER=github SOURCE_2_REMOTE_HOSTS=checkout-github SOURCE_2_API_HOST=github.example SOURCE_2_ORGANIZATION=acme SOURCE_2_USERNAME=fixture-gh
  # shellcheck disable=SC2034
  SOURCE_1_ACTIVITY_TYPES=commits SOURCE_2_ACTIVITY_TYPES=commits SOURCE_1_ACCESS_MODE=remote SOURCE_2_ACCESS_MODE=remote
  # shellcheck disable=SC2034
  SOURCE_1_EMAILS=author@example.test SOURCE_2_EMAILS=author@example.test SOURCE_1_SINCE=2021-01-01 SOURCE_2_SINCE=2021-01-01
  mkdir -p "$WORK_DIRS"
  git clone --mirror --quiet "$TEST_ROOT/remotes/source.git" "$TEST_ROOT/remotes/source=exact.git"
  for provider in gitlab github; do
    case "$provider" in gitlab) bare="$TEST_ROOT/remotes/source=exact.git"; project=team/repo ;; github) bare="$TEST_ROOT/remotes/github-source.git"; project=AcMe/ApP ;; esac
    git clone --quiet "$bare" "$WORK_DIRS/$provider"
    git -C "$WORK_DIRS/$provider" remote set-url origin "https://checkout-$provider/$project"
    git -C "$WORK_DIRS/$provider" config url."$bare".insteadOf "https://checkout-$provider/$project"
  done
  # Native access to A performs only the local A -> B rewrite. A later global
  # B -> C must not redirect indexed preflight/fetch to this distinct history.
  git init --quiet "$TEST_ROOT/wrong-rewrite-work"
  GIT_AUTHOR_DATE=2021-01-15T12:00:00Z GIT_COMMITTER_DATE=2021-01-15T12:00:00Z \
    git -C "$TEST_ROOT/wrong-rewrite-work" commit --quiet --allow-empty -m 'wrong repository activity'
  wrong_sha="$(git -C "$TEST_ROOT/wrong-rewrite-work" rev-parse HEAD)"
  git clone --bare --quiet "$TEST_ROOT/wrong-rewrite-work" "$TEST_ROOT/wrong-rewrite.git"
  git config --global url."$TEST_ROOT/wrong-rewrite.git".insteadOf "$TEST_ROOT/remotes/source=exact.git"
  native_sha="$(git -C "$WORK_DIRS/gitlab" ls-remote origin refs/heads/main | cut -f1)"
  git init --bare --quiet "$TEST_ROOT/remotes/checkout-rewrite-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$MIRROR_URL"
  git config --global url."$TEST_ROOT/remotes/checkout-rewrite-mirror.git".insteadOf "$MIRROR_URL"
  greens_save_config "$CONFIG_FILE" WORK_DIRS SCAN_MODE SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_REMOTE_HOSTS SOURCE_1_API_HOST SOURCE_1_ORGANIZATION SOURCE_1_USERNAME SOURCE_1_EMAILS SOURCE_1_SINCE SOURCE_1_ACTIVITY_TYPES SOURCE_1_ACCESS_MODE SOURCE_2_PROVIDER SOURCE_2_REMOTE_HOSTS SOURCE_2_API_HOST SOURCE_2_ORGANIZATION SOURCE_2_USERNAME SOURCE_2_EMAILS SOURCE_2_SINCE SOURCE_2_ACTIVITY_TYPES SOURCE_2_ACCESS_MODE MIRROR_DIR MIRROR_URL CACHE_DIR LOG_DIR MIRROR_EMAIL
  greens_mixed_discover_checkouts > "$TEST_ROOT/checkout-rewrite-discovery"
  awk -F '\t' -v target="$TEST_ROOT/remotes/source=exact.git" '$2=="forge.example/team/repo" && $3==target {found=1} END {exit !found}' "$TEST_ROOT/checkout-rewrite-discovery" || fail "discovery lost GitLab identity or local transport"
  awk -F '\t' -v target="$TEST_ROOT/remotes/github-source.git" '$2=="github.example/acme/app" && $3==target {found=1} END {exit !found}' "$TEST_ROOT/checkout-rewrite-discovery" || fail "discovery lost GitHub identity or local transport"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 4 ]] || fail "checkout-local rewrites omitted source commits"
  jq -es --arg wrong "$wrong_sha" --arg native "$native_sha" 'all(.[]; (.key|contains($wrong)|not)) and any(.[]; .key|contains($native))' "$CACHE_DIR"/activity-state/*/*.jsonl >/dev/null || fail "a second rewrite imported the wrong repository"
  first_head="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  {
    printf 'y\n'
    printf '\n%.0s' {1..15}
    printf 'n\n'
  } | SCHEDULER=manual CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/setup.sh" > "$TEST_ROOT/checkout-rewrite-setup" 2>&1 || {
    cat "$TEST_ROOT/checkout-rewrite-setup"; fail "setup lost checkout-local rewrites";
  }
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$first_head" ]] || fail "checkout rewrite rerun duplicated activity"
  [[ "$(git -C "$WORK_DIRS/github" config remote.origin.url)" == https://checkout-github/AcMe/ApP ]] || fail "source origin was replaced with expanded transport"
  git config --global --unset-all url."$TEST_ROOT/wrong-rewrite.git".insteadOf
) || fail "checkout-local transport rewrite regression"
echo "PASS: checkout-local rewrites survive source discovery, cached sync, setup rerun and provider identity grouping"

# Real setup in a simulated Homebrew Cellar must install upgrade-stable jobs.
# After removing that Cellar version, the saved runner must execute the new one.
brew_prefix="$TEST_ROOT/brew"
old_keg="$brew_prefix/Cellar/greens/1.9.0"
new_keg="$brew_prefix/Cellar/greens/2.0.0"
mkdir -p "$old_keg/libexec" "$new_keg/libexec" "$brew_prefix/opt"
cp "$ROOT/setup.sh" "$old_keg/libexec/setup.sh"
cp -R "$ROOT/lib" "$old_keg/libexec/lib"
printf '#!/bin/bash\necho old > "$TEST_ROOT/brew-version"\n' > "$old_keg/libexec/sync.sh"
printf '#!/bin/bash\necho new > "$TEST_ROOT/brew-version"\n' > "$new_keg/libexec/sync.sh"
ln -s "$old_keg" "$brew_prefix/opt/greens"
stable_sync="$brew_prefix/opt/greens/libexec/sync.sh"
brew_config="$TEST_ROOT/brew-config"
cp "$TEST_ROOT/ssh-only-config" "$brew_config"
{
  printf 'y\n'
  printf '\n%.0s' {1..12}
  printf 'n\n'
} | SCHEDULER=cron CONTRIB_MIRROR_CONFIG="$brew_config" bash "$old_keg/libexec/setup.sh" > "$TEST_ROOT/brew-setup-output" 2>&1 || {
  cat "$TEST_ROOT/brew-setup-output"; fail "Homebrew setup";
}
grep -Fq "$stable_sync" "$TEST_ROOT/crontab" || fail "setup scheduled a versioned Homebrew path"
CONFIG_FILE="$brew_config"
greens_install_systemd "$old_keg/libexec/sync.sh" 7
brew_runner="$(dirname "$CONFIG_FILE")/$(greens_scheduler_id)-run"
grep -Fq "$stable_sync" "$brew_runner" || fail "systemd runner used Cellar path"
cat > "$TEST_ROOT/bin/launchctl" <<'MOCK'
#!/bin/bash
case "$1" in bootout|bootstrap) exit 0 ;; *) exit 1 ;; esac
MOCK
greens_install_launchd "$old_keg/libexec/sync.sh" 7
grep -Fq "$stable_sync" "$HOME/Library/LaunchAgents/$(greens_launchd_label).plist" || fail "launchd used Cellar path"
cat > "$TEST_ROOT/bin/schtasks.exe" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/brew-windows-task"
MOCK
cat > "$TEST_ROOT/bin/cmd.exe" <<'MOCK'
#!/bin/bash
echo fixture-user
MOCK
chmod +x "$TEST_ROOT/bin/schtasks.exe" "$TEST_ROOT/bin/cmd.exe"
greens_install_windows_task "$old_keg/libexec/sync.sh" 7
grep -Fq "$stable_sync" "$TEST_ROOT/brew-windows-task" || fail "Task Scheduler used Cellar path"
rm "$brew_prefix/opt/greens"
ln -s "$new_keg" "$brew_prefix/opt/greens"
rm -rf "$old_keg"
bash "$brew_runner"
[[ "$(cat "$TEST_ROOT/brew-version")" == new ]] || fail "scheduled runner failed after Homebrew cleanup"
[[ "$(greens_sync_path "$ROOT/sync.sh")" == "$ROOT/sync.sh" ]] || fail "changed a non-Homebrew install path"
echo "PASS: Homebrew setup and schedulers survive version cleanup and upgrade"

# A cron environment may have no jq (or even no usable PATH). The generated
# command must retain the setup PATH, including spaces and cron's '%' syntax.
mkdir -p "$TEST_ROOT/cron deps %" "$TEST_ROOT/empty-path"
ln -s "$(command -v jq)" "$TEST_ROOT/cron deps %/jq"
cat > "$TEST_ROOT/cron program" <<'FIXTURE'
#!/bin/bash
printf '%s\n' "$PATH" > "$TEST_ROOT/cron-used-path"
printf '%s\n' "$CONTRIB_MIRROR_CONFIG" > "$TEST_ROOT/cron-used-config"
command -v jq > "$TEST_ROOT/cron-used-jq"
jq -n '{ready:true}' > "$TEST_ROOT/cron-result"
FIXTURE
CONFIG_FILE="$TEST_ROOT/cron config with spaces"
setup_path="$TEST_ROOT/cron deps %:$PATH"
PATH="$setup_path" greens_install_cron "$TEST_ROOT/cron program" 6
cron_command="$(crontab -l | grep "# $(greens_scheduler_id)$" | cut -d ' ' -f6-)"
PATH="$TEST_ROOT/empty-path" /bin/sh -c "$cron_command" || fail "cron could not use setup dependencies"
[[ "$(cat "$TEST_ROOT/cron-used-path")" == "$setup_path" ]] || fail "cron lost setup PATH"
[[ "$(cat "$TEST_ROOT/cron-used-config")" == "$CONFIG_FILE" ]] || fail "cron lost selected config"
[[ "$(cat "$TEST_ROOT/cron-used-jq")" == "$TEST_ROOT/cron deps %/jq" ]] || fail "cron selected a different jq"
jq -e .ready "$TEST_ROOT/cron-result" > /dev/null || fail "cron dependency did not execute"
echo "PASS: cron preserves setup PATH with spaces and percent signs"

# Fresh grouping must retain aliases literally: github.com is not a regex
# matching github-com. Reject actual mirror pushes to exercise optional initial
# sync failures while installing/replacing the selected daily cron job.
(
  alias_work="$TEST_ROOT/literal-alias-work"
  alias_failure_config="$TEST_ROOT/literal-alias-config"
  mkdir -p "$alias_work"
  for checkout in alias public; do
    git clone --quiet --branch main "$TEST_ROOT/remotes/source.git" "$alias_work/$checkout"
  done
  git -C "$alias_work/alias" remote set-url origin git@github-com:team/a.git
  git -C "$alias_work/public" remote set-url origin https://github.com/team/b.git
  git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf git@github-com:team/a.git
  git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf https://github.com/team/b.git
  git config --global --add url."$TEST_ROOT/remotes/mirror.git".insteadOf https://github.com/fixture/mirror
  printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/remotes/mirror.git/hooks/pre-receive"
  chmod +x "$TEST_ROOT/remotes/mirror.git/hooks/pre-receive"
  {
    printf '%s\n\n\nauthor@example.test\ncommits\n2021-01-01\n' "$alias_work"
    printf 'fixture\nmirror@example.test\ngreens\nhttps://github.com/fixture/mirror\n%s\ncron\n6\ny\n' "$TEST_ROOT/literal-alias-mirror"
  } | CONTRIB_MIRROR_CONFIG="$alias_failure_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/initial-failure-output" 2>&1 || {
    cat "$TEST_ROOT/initial-failure-output"; fail "fresh setup aborted on optional sync failure";
  }
  bash -c 'source "$1"; [[ "$SOURCE_COUNT" == 1 && "$SOURCE_1_REMOTE_HOSTS" == github-com,github.com && "$SCHEDULER" == cron && "$SYNC_HOUR" == 6 ]]' bash "$alias_failure_config" || fail "fresh setup lost literal aliases or selected schedule"
  bash -c 'source "$1/lib/common.sh"; source "$1/lib/gitlab.sh"; source "$2"; CACHE_DIR="$HOME/.contrib-mirror/cache"; greens_mixed_discover_checkouts' bash "$ROOT" "$alias_failure_config" > "$TEST_ROOT/literal-alias-checkouts"
  [[ "$(wc -l < "$TEST_ROOT/literal-alias-checkouts" | tr -d ' ')" == 2 ]] || fail "literal alias grouping omitted a counted checkout"
  grep -q 'Collecting github team/a' "$TEST_ROOT/initial-failure-output" || fail "initial sync omitted dashed alias"
  grep -q 'Collecting github team/b' "$TEST_ROOT/initial-failure-output" || fail "initial sync omitted dotted hostname"
  grep -q 'remote rejected' "$TEST_ROOT/initial-failure-output" || fail "initial sync did not exercise a real push failure"
  grep -q 'Initial sync failed' "$TEST_ROOT/initial-failure-output" || fail "initial sync failure was hidden"
  grep -q 'Setup saved, but the initial sync failed' "$TEST_ROOT/initial-failure-output" || fail "fresh setup did not finish"
  if grep -q 'Setup complete' "$TEST_ROOT/initial-failure-output"; then fail "fresh setup reported success after a failed sync"; fi
  grep -q 'Include private contributions on my profile' "$TEST_ROOT/initial-failure-output" || fail "setup did not mention the private contributions setting"
  CONFIG_FILE="$alias_failure_config"
  schedule_id="$(greens_scheduler_id)"
  crontab -l | grep "# $schedule_id$" > "$TEST_ROOT/failure-schedule"
  grep -q '^0 6 ' "$TEST_ROOT/failure-schedule" || fail "failed initial sync left fresh setup unscheduled"
  [[ "$(wc -l < "$TEST_ROOT/failure-schedule" | tr -d ' ')" == 1 ]] || fail "fresh setup installed duplicate jobs"
  {
    printf 'y\n'
    printf '\n%.0s' {1..11}
    printf '17\ny\n'
  } | CONTRIB_MIRROR_CONFIG="$alias_failure_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/rerun-failure-output" 2>&1 || {
    cat "$TEST_ROOT/rerun-failure-output"; fail "rerun setup aborted on optional sync failure";
  }
  grep -q 'remote rejected' "$TEST_ROOT/rerun-failure-output" || fail "rerun did not retry the failed push"
  grep -q 'Initial sync failed' "$TEST_ROOT/rerun-failure-output" || fail "rerun hid the sync failure"
  grep -q 'Setup saved, but the initial sync failed' "$TEST_ROOT/rerun-failure-output" || fail "rerun setup did not finish"
  if grep -q 'Setup complete' "$TEST_ROOT/rerun-failure-output"; then fail "rerun setup reported success after a failed sync"; fi
  crontab -l | grep "# $schedule_id$" > "$TEST_ROOT/failure-schedule"
  grep -q '^0 17 ' "$TEST_ROOT/failure-schedule" || fail "failed initial sync retained the old schedule"
  [[ "$(wc -l < "$TEST_ROOT/failure-schedule" | tr -d ' ')" == 1 ]] || fail "rerun retained duplicate schedules"
  bash -c 'source "$1"; [[ "$SOURCE_1_REMOTE_HOSTS" == github-com,github.com && "$SYNC_HOUR" == 17 ]]' bash "$alias_failure_config" || fail "rerun lost aliases or changed hour"
  rm "$TEST_ROOT/remotes/mirror.git/hooks/pre-receive"
) || fail "literal aliases and scheduling after initial sync failure"
echo "PASS: literal hostname aliases and scheduler installation/replacement after failed initial pushes"

# Narrowing a recursive scan removes groups which still exist only deeper in
# an available root, while preserving a genuinely unavailable saved source.
(
  depth_work="$TEST_ROOT/depth-work" depth_config="$TEST_ROOT/depth-config"
  mkdir -p "$depth_work/nested"
  for checkout in first second nested/repo; do
    git clone --quiet --branch main "$TEST_ROOT/remotes/source.git" "$depth_work/$checkout"
  done
  for pair in first:2222 second:2223; do
    url="ssh://git@forge.example:${pair#*:}/visible/repo.git"
    git -C "$depth_work/${pair%%:*}" remote set-url origin "$url"
    git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf "$url"
  done
  git -C "$depth_work/nested/repo" remote set-url origin git@forge.example:nested-only/repo.git
  cp "$TEST_ROOT/ssh-only-config" "$depth_config"
  # Config values are consumed by name in greens_save_config.
  # shellcheck disable=SC2034
  WORK_DIRS="$depth_work" SCAN_MODE=recursive SOURCE_COUNT=3 MIRROR_DIR="$TEST_ROOT/depth-mirror" \
    SOURCE_1_PROVIDER=git SOURCE_1_API_HOST=forge.example SOURCE_1_REMOTE_HOSTS=forge.example SOURCE_1_ORGANIZATION=visible SOURCE_1_ACCESS_MODE=remote \
    SOURCE_2_PROVIDER=git SOURCE_2_API_HOST=forge.example SOURCE_2_REMOTE_HOSTS=forge.example SOURCE_2_ORGANIZATION=nested-only \
    SOURCE_2_USERNAME='' SOURCE_2_EMAILS=author@example.test SOURCE_2_SINCE=2021-01-01 SOURCE_2_ACTIVITY_TYPES=commits SOURCE_2_ACCESS_MODE=local \
    SOURCE_3_PROVIDER=git SOURCE_3_API_HOST=forge.example SOURCE_3_REMOTE_HOSTS=forge.example SOURCE_3_ORGANIZATION=unavailable \
    SOURCE_3_USERNAME='' SOURCE_3_EMAILS=author@example.test SOURCE_3_SINCE=2021-01-01 SOURCE_3_ACTIVITY_TYPES=commits SOURCE_3_ACCESS_MODE=remote
  greens_save_config "$depth_config" WORK_DIRS SCAN_MODE SOURCE_COUNT MIRROR_DIR \
    SOURCE_1_PROVIDER SOURCE_1_API_HOST SOURCE_1_REMOTE_HOSTS SOURCE_1_ORGANIZATION SOURCE_1_ACCESS_MODE \
    SOURCE_2_PROVIDER SOURCE_2_API_HOST SOURCE_2_REMOTE_HOSTS SOURCE_2_ORGANIZATION SOURCE_2_USERNAME SOURCE_2_EMAILS SOURCE_2_SINCE SOURCE_2_ACTIVITY_TYPES SOURCE_2_ACCESS_MODE \
    SOURCE_3_PROVIDER SOURCE_3_API_HOST SOURCE_3_REMOTE_HOSTS SOURCE_3_ORGANIZATION SOURCE_3_USERNAME SOURCE_3_EMAILS SOURCE_3_SINCE SOURCE_3_ACTIVITY_TYPES SOURCE_3_ACCESS_MODE
  {
    printf 'y\n'
    printf '\n%.0s' {1..11}
    printf 'n\n'
  } | CONTRIB_MIRROR_CONFIG="$depth_config" bash "$ROOT/setup.sh" --in-root > "$TEST_ROOT/depth-output" 2>&1 || {
    cat "$TEST_ROOT/depth-output"; fail "setup scan-depth change";
  }
  bash -c 'source "$1"; [[ "$SCAN_MODE" == in-root && "$SOURCE_COUNT" == 2 && "$SOURCE_1_ORGANIZATION" == visible && "$SOURCE_2_ORGANIZATION" == unavailable && "$SOURCE_2_ACCESS_MODE" == remote && -z "${SOURCE_3_PROVIDER:-}" ]]' bash "$depth_config" || fail "scan-depth change retained an excluded group or lost an offline group"
  grep -q 'outside the immediate child folders' "$TEST_ROOT/depth-output" || fail "scan-depth removal was not explained"
  grep -q 'skip all 2 repositories' "$TEST_ROOT/depth-output" || fail "setup merged distinct generic endpoints in its count"
  FORCE=1 CONTRIB_MIRROR_CONFIG="$depth_config" bash "$ROOT/sync.sh" > "$TEST_ROOT/depth-sync-output" 2>&1 || {
    cat "$TEST_ROOT/depth-sync-output"; fail "fresh sync failed after narrowing scan depth";
  }
) || fail "scan-depth source regeneration regression"
echo "PASS: explicit in-root scan drops excluded local groups, retains unavailable sources, and syncs successfully"

# A fresh generic setup may contain only unnamespaced repository paths. Keep
# known-provider owner/repo validation after classifying the raw origins.
(
  root_work="$TEST_ROOT/root-path-work" root_config="$TEST_ROOT/root-path-config"
  mkdir -p "$root_work" "$TEST_ROOT/root-path-bin"
  for tool in glab curl; do
    printf '#!/bin/bash\nexit 1\n' > "$TEST_ROOT/root-path-bin/$tool"
    chmod +x "$TEST_ROOT/root-path-bin/$tool"
  done
  for transport in scp ssh https; do
    case "$transport" in
      scp) url=git@flat.example:project.git ;;
      ssh) url=ssh://git@flat.example:2222/project.git ;;
      https) url=https://flat.example:8443/project.git ;;
    esac
    git clone --quiet --branch main "$TEST_ROOT/remotes/source.git" "$root_work/$transport"
    git -C "$root_work/$transport" remote set-url origin "$url"
    git config --global --add url."$TEST_ROOT/remotes/source.git".insteadOf "$url"
  done
  git init --quiet "$root_work/invalid-github"
  git -C "$root_work/invalid-github" remote add origin git@github.com:project.git
  {
    printf '%s\n\n\n3\nauthor@example.test\n2021-01-01\n' "$root_work"
    printf 'fixture\nmirror@example.test\ngreens\nhttps://github.com/fixture/mirror\n%s\nmanual\n0\ny\n' "$TEST_ROOT/root-path-mirror"
  } | PATH="$TEST_ROOT/root-path-bin:$PATH" CONTRIB_MIRROR_CONFIG="$root_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/root-path-output" 2>&1 || {
    cat "$TEST_ROOT/root-path-output"; fail "fresh generic root-path setup";
  }
  bash -c 'source "$1"; [[ "$SOURCE_COUNT" == 1 && "$SOURCE_1_PROVIDER" == git && "$SOURCE_1_ORGANIZATION" == project && "$SOURCE_1_ACCESS_MODE" == remote ]]' bash "$root_config" || fail "root-path setup did not preserve generic sources or validated an invalid GitHub path"
  grep -q 'skip all 3 repositories' "$TEST_ROOT/root-path-output" || fail "setup omitted a root-level origin"
  [[ "$(grep -c 'Collecting git project' "$TEST_ROOT/root-path-output")" == 3 ]] || fail "root-level sources were not collected"
  if grep -q 'Initial sync failed' "$TEST_ROOT/root-path-output"; then cat "$TEST_ROOT/root-path-output"; fail "initial root-path sync failed"; fi
  CONFIG_FILE="$root_config"
  jq -s 'map(.key|split("/commit/")[0])|unique|length' "$HOME/.contrib-mirror/cache/activity-state/$(greens_scheduler_id)-"*/*.jsonl > "$TEST_ROOT/root-path-endpoints"
  [[ "$(cat "$TEST_ROOT/root-path-endpoints")" == 3 ]] || fail "root-level endpoints merged in activity state"
  before="$(git -C "$TEST_ROOT/root-path-mirror" log --format=%B | grep -c '^Greens-Activity: ')"
  FORCE=1 CONTRIB_MIRROR_CONFIG="$root_config" bash "$ROOT/sync.sh" > "$TEST_ROOT/root-path-fresh-output" 2>&1 || {
    cat "$TEST_ROOT/root-path-fresh-output"; fail "fresh generic root-path sync";
  }
  [[ "$(git -C "$TEST_ROOT/root-path-mirror" log --format=%B | grep -c '^Greens-Activity: ')" == "$before" ]] || fail "root-path rerun duplicated activities"
) || fail "generic root-level repository regression"
echo "PASS: fresh generic root-path setup, SSH/HTTPS collection, provider validation, and idempotent sync"

# Parse the actual generated XML and verify every interpolated filesystem path
# round-trips literally, including entity-like text and all XML metacharacters.
(
  CONFIG_FILE="$TEST_ROOT/Work & Personal <config> \"quoted\" 'single' &amp;/config"
  LOG_DIR="$TEST_ROOT/logs & <output> \"quoted\" 'single'"
  xml_script="$TEST_ROOT/runtime & <tools>/sync \"quoted\" 'single'.sh"
  mkdir -p "$(dirname "$xml_script")"
  mkdir -p "$TEST_ROOT/launchd deps & <tools>"
  printf '#!/bin/bash\nprintf "ready"\n' > "$TEST_ROOT/launchd deps & <tools>/glab"
  chmod +x "$TEST_ROOT/launchd deps & <tools>/glab"
  printf '#!/bin/bash\ncommand -v glab > "$TEST_ROOT/launchd-used-glab"\nglab > "$TEST_ROOT/launchd-result"\n' > "$xml_script"
  PATH="$TEST_ROOT/launchd deps & <tools>:$PATH" greens_install_launchd "$xml_script" 7
  python3 - "$HOME/Library/LaunchAgents/$(greens_launchd_label).plist" "$CONFIG_FILE" "$xml_script" "$LOG_DIR" "$(greens_launchd_label)" <<'CHECK'
import pathlib
import plistlib
import sys
plist, config, script, logs, label = sys.argv[1:]
with open(plist, "rb") as stream:
    agent = plistlib.load(stream)
assert agent["Label"] == label
assert agent["ProgramArguments"] == ["/bin/bash", script]
assert agent["EnvironmentVariables"]["CONTRIB_MIRROR_CONFIG"] == config
assert agent["StandardOutPath"] == str(pathlib.Path(logs) / "sync.out.log")
assert agent["StandardErrorPath"] == str(pathlib.Path(logs) / "sync.err.log")
assert agent["StartCalendarInterval"] == {"Hour": 7, "Minute": 0}
import os
import subprocess
env = dict(os.environ)
env.update(agent["EnvironmentVariables"])
subprocess.run(agent["ProgramArguments"], env=env, check=True)
assert pathlib.Path(os.environ["TEST_ROOT"], "launchd-used-glab").read_text().strip() == str(pathlib.Path(os.environ["TEST_ROOT"], "launchd deps & <tools>", "glab"))
assert pathlib.Path(os.environ["TEST_ROOT"], "launchd-result").read_text() == "ready"
CHECK
) || fail "launchd XML path escaping regression"
echo "PASS: launchd plist preserves config, executable and log paths containing XML metacharacters"

# Upgrade seeding is local, independent, and does not copy old transport auth.
(
  old="$TEST_ROOT/old-cache.git" seeded="$TEST_ROOT/new-cache/seed.git"
  git clone --bare --quiet "$TEST_ROOT/remotes/source.git" "$old"
  git --git-dir="$old" config credential.helper '!echo old-private-helper'
  git --git-dir="$old" config http.extraHeader 'Authorization: fixture-old'
  greens_seed_bare_cache "$seeded" "$old"
  [[ "$(git --git-dir="$seeded" rev-parse HEAD)" == "$(git --git-dir="$old" rev-parse HEAD)" ]] || fail "cache seed lost repository history"
  if git --git-dir="$seeded" config --get credential.helper >/dev/null || git --git-dir="$seeded" config --get http.extraHeader >/dev/null || git --git-dir="$seeded" remote get-url origin >/dev/null 2>&1; then fail "cache seed copied old transport credentials"; fi
  git --git-dir="$seeded" update-ref refs/heads/seed-only HEAD
  if git --git-dir="$old" rev-parse --verify refs/heads/seed-only >/dev/null 2>&1; then fail "cache seed shares mutable refs"; fi
) || fail "upgrade bare-cache seeding regression"
echo "PASS: local cache migration retains history without copying transport credentials or sharing refs"

# Migrate working filesystem-origin repositories without losing either source.
# URI/absolute aliases deduplicate; relative paths resolve from their checkout,
# and URL escapes preserve spaces, UTF-8 and literal percent characters.
(
  fs_remotes="$TEST_ROOT/filesystem remotes %"
  fs_work="$TEST_ROOT/filesystem-work" fs_config="$TEST_ROOT/filesystem-config"
  mkdir -p "$fs_remotes" "$fs_work"
  for number in 1 2 3; do
    git init --quiet "$TEST_ROOT/fs-source-$number"
    git -C "$TEST_ROOT/fs-source-$number" symbolic-ref HEAD refs/heads/main
    GIT_AUTHOR_DATE="2021-01-0${number}T12:00:00Z" GIT_COMMITTER_DATE="2021-01-0${number}T12:00:00Z" \
      git -C "$TEST_ROOT/fs-source-$number" commit --quiet --allow-empty -m "filesystem source $number"
    git clone --bare --quiet "$TEST_ROOT/fs-source-$number" "$fs_remotes/source-$number.git"
    [[ "$number" != 3 ]] || continue
    git clone --quiet "$fs_remotes/source-$number.git" "$fs_work/source-$number"
  done
  git init --bare --quiet "$TEST_ROOT/filesystem-mirror.git"
  git --git-dir="$TEST_ROOT/filesystem-mirror.git" symbolic-ref HEAD refs/heads/main
  git init --quiet "$TEST_ROOT/filesystem-mirror"
  git -C "$TEST_ROOT/filesystem-mirror" symbolic-ref HEAD refs/heads/main
  git -C "$TEST_ROOT/filesystem-mirror" remote add origin https://github.com/fixture/mirror.git
  git config --global url."$TEST_ROOT/filesystem-mirror.git".insteadOf https://github.com/fixture/mirror.git
  # Values are consumed by name by greens_save_config.
  # shellcheck disable=SC2034
  SOURCE_PROVIDER=github WORK_DIR="$fs_work" REMOTE_PREFIX="$fs_remotes/" \
    MIRROR_DIR="$TEST_ROOT/filesystem-mirror" MIRROR_URL=https://github.com/fixture/mirror.git \
    CACHE_DIR="$TEST_ROOT/filesystem-cache" LOG_DIR="$TEST_ROOT/filesystem-logs" \
    EMAILS=author@example.test MIRROR_EMAIL=mirror@example.test MIRROR_NAME=greens \
    PERSONAL_GH_USER=fixture GITHUB_USERNAME=fixture ACTIVITY_TYPES=commits \
    SINCE='2021-01-01 00:00:00' SCHEDULER=manual SYNC_HOUR=0
  greens_save_config "$fs_config" SOURCE_PROVIDER WORK_DIR REMOTE_PREFIX MIRROR_DIR MIRROR_URL CACHE_DIR LOG_DIR \
    EMAILS MIRROR_EMAIL MIRROR_NAME PERSONAL_GH_USER GITHUB_USERNAME ACTIVITY_TYPES SINCE SCHEDULER SYNC_HOUR
  FORCE=1 CONTRIB_MIRROR_CONFIG="$fs_config" bash "$ROOT/sync.sh" > "$TEST_ROOT/fs-legacy-output" 2>&1 || {
    cat "$TEST_ROOT/fs-legacy-output"; fail "legacy filesystem sync";
  }
  [[ "$(git -C "$MIRROR_DIR" log --format=%H --author='<mirror@example.test>' | wc -l | tr -d ' ')" == 2 ]] || fail "legacy filesystem sync omitted a source"
  git clone --quiet "$fs_remotes/source-1.git" "$fs_work/source-1-uri"
  first_uri="$(greens_remote_identity "$fs_remotes/source-1.git" 1)"
  second_uri="$(greens_remote_identity "$fs_remotes/source-2.git" 1)"
  git -C "$fs_work/source-1-uri" remote set-url origin "$first_uri"
  git -C "$fs_work/source-2" remote set-url origin "file://localhost${second_uri#file://}"
  git clone --quiet "$fs_remotes/source-3.git" "$fs_work/relative"
  git -C "$fs_work/relative" remote set-url origin '../../filesystem remotes %/source-3.git'
  git clone --quiet "$fs_remotes/source-1.git" "$fs_work/source-1-relative"
  git -C "$fs_work/source-1-relative" remote set-url origin '../../filesystem remotes %/source-1.git'
  [[ "$(greens_remote_identity "$first_uri" 1)" == "$first_uri" ]] || fail "file URI escaping did not round-trip"
  [[ "$(greens_uri_path_decode "$(greens_uri_path_encode 'space % é')")" == 'space % é' ]] || fail "filesystem URI byte encoding"
  {
    printf 'y\n'
    printf '\n%.0s' {1..11}
    printf 'y\n'
  } | CONTRIB_MIRROR_CONFIG="$fs_config" bash "$ROOT/setup.sh" > "$TEST_ROOT/fs-setup-output" 2>&1 || {
    cat "$TEST_ROOT/fs-setup-output"; fail "filesystem migration setup";
  }
  bash -c 'source "$1"; [[ "$SOURCE_COUNT" == 1 && "$SOURCE_1_PROVIDER" == git && "$SOURCE_1_REMOTE_HOSTS" == file://localhost && "$SOURCE_1_ACCESS_MODE" == remote && "$GREENS_LEGACY_TIMESTAMPS" == 1 && -z "${SOURCE_PROVIDER:-}" ]]' bash "$fs_config" || fail "filesystem migration did not retain its complete source group"
  grep -q 'skip all 3 repositories' "$TEST_ROOT/fs-setup-output" || fail "filesystem origin alias deduplication or discovery failed"
  if grep -q 'Initial sync failed' "$TEST_ROOT/fs-setup-output"; then cat "$TEST_ROOT/fs-setup-output"; fail "initial filesystem sync after migration"; fi
  [[ "$(git -C "$MIRROR_DIR" log --format=%H --author='<mirror@example.test>' | wc -l | tr -d ' ')" == 3 ]] || fail "migration lost a filesystem source or duplicated legacy timestamps"
  FORCE=1 CONTRIB_MIRROR_CONFIG="$fs_config" bash "$ROOT/sync.sh" > "$TEST_ROOT/fs-fresh-output" 2>&1 || {
    cat "$TEST_ROOT/fs-fresh-output"; fail "fresh indexed filesystem sync";
  }
  [[ "$(git -C "$MIRROR_DIR" log --format=%H --author='<mirror@example.test>' | wc -l | tr -d ' ')" == 3 ]] || fail "filesystem rerun duplicated activity"
) || fail "filesystem origins and legacy migration regression"
echo "PASS: filesystem origin migration, file URI aliases, relative remotes, escaping and fresh sync"

# GitHub repository IDs survive renames, including upgrades from old path/case
# markers, without suppressing a distinct repository with the same commit SHA.
(
  CONFIG_FILE="$TEST_ROOT/github-rename-config" WORK_DIRS="$TEST_ROOT/github-rename-work" SCAN_MODE=in-root SOURCE_COUNT=1
  MIRROR_DIR="$TEST_ROOT/github-rename-mirror" MIRROR_URL=https://github-rename@github.com/fixture/mirror
  CACHE_DIR="$TEST_ROOT/github-rename-cache" LOG_DIR="$TEST_ROOT/github-rename-logs" MIRROR_EMAIL=mirror@example.test
  # Values are read through indexed accessors and greens_save_config.
  # shellcheck disable=SC2034
  SOURCE_1_PROVIDER=github SOURCE_1_API_HOST=github.example SOURCE_1_REMOTE_HOSTS=github.example SOURCE_1_ORGANIZATION=acme SOURCE_1_USERNAME=fixture-gh \
    SOURCE_1_EMAILS=author@example.test SOURCE_1_SINCE=2021-01-01 SOURCE_1_ACTIVITY_TYPES=commits,issues SOURCE_1_ACCESS_MODE=remote
  git clone --quiet --branch main "$TEST_ROOT/remotes/github-source.git" "$WORK_DIRS/repo"
  sha="$(git -C "$WORK_DIRS/repo" rev-parse HEAD)"
  for path in old new third fork; do git config --global --add url."$TEST_ROOT/remotes/github-source.git".insteadOf "git@github.example:acme/$path.git"; done
  git -C "$WORK_DIRS/repo" remote set-url origin git@github.example:acme/old.git
  git init --bare --quiet "$TEST_ROOT/remotes/github-rename-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$MIRROR_URL"
  git config --global url."$TEST_ROOT/remotes/github-rename-mirror.git".insteadOf "$MIRROR_URL"
  greens_save_config "$CONFIG_FILE" WORK_DIRS SCAN_MODE SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_API_HOST SOURCE_1_REMOTE_HOSTS SOURCE_1_ORGANIZATION SOURCE_1_USERNAME SOURCE_1_EMAILS SOURCE_1_SINCE SOURCE_1_ACTIVITY_TYPES SOURCE_1_ACCESS_MODE MIRROR_DIR MIRROR_URL CACHE_DIR LOG_DIR MIRROR_EMAIL
  touch "$TEST_ROOT/github-rename-fixture"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  first_tip="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 1 ]] || fail "GitHub rename initial activity count"
  git -C "$MIRROR_DIR" log --format=%B | grep -q "$(printf '%s' "github.example/801/commit/$sha" | greens_hash)" || fail "GitHub commit key did not use repository ID"
  git -C "$WORK_DIRS/repo" remote set-url origin git@github.example:acme/new.git
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$first_tip" ]] || fail "GitHub rename replayed unchanged commits"
  old_key="github.example/AcMe/Old/commit/$sha"
  GIT_AUTHOR_DATE=2021-02-03T12:30:00Z GIT_COMMITTER_DATE=2021-02-03T12:30:00Z \
    git -C "$MIRROR_DIR" commit --amend --allow-empty --quiet -m "$(printf 'sync\n\nGreens-Activity: %s' "$(printf '%s' "$old_key" | greens_hash)")"
  git -C "$MIRROR_DIR" push --force --quiet origin HEAD:refs/heads/main
  old_path_key="$(printf '%s' github.example/acme/old | greens_hash)"
  for cached in "$CACHE_DIR"/activity-state/*/"$old_path_key.jsonl"; do
    [[ -f "$cached" ]] || continue
    jq -c --arg key "$old_key" 'if .kind=="commits" then .key=$key else . end' "$cached" > "$cached.old"; mv "$cached.old" "$cached"
  done
  rm -rf "$CACHE_DIR/github-projects"
  git -C "$WORK_DIRS/repo" remote set-url origin git@github.example:acme/third.git
  legacy_tip="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$legacy_tip" ]] || fail "GitHub rename failed to recognize old path/case marker"
  SOURCE_1_ACTIVITY_TYPES=commits; greens_save_config "$CONFIG_FILE" SOURCE_1_ACTIVITY_TYPES
  rm -f "$TEST_ROOT/github-source-api-called"; touch "$TEST_ROOT/forbid-github-source-api"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  rm "$TEST_ROOT/forbid-github-source-api"
  [[ ! -e "$TEST_ROOT/github-source-api-called" && "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$legacy_tip" ]] || fail "GitHub commits-only transition lost verified repository ID"
  # shellcheck disable=SC2034
  SOURCE_1_ACTIVITY_TYPES=commits,issues; greens_save_config "$CONFIG_FILE" SOURCE_1_ACTIVITY_TYPES
  git -C "$WORK_DIRS/repo" remote set-url origin git@github.example:acme/fork.git
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 2 ]] || fail "distinct GitHub repository sharing a SHA was suppressed"
  rm "$TEST_ROOT/github-rename-fixture"
) || fail "stable GitHub repository commit identities"
echo "PASS: GitHub renames, pre-ID path/case markers, commits-only transitions and distinct repository identities"

# Both dashboards publish only repository names for filesystem sources. Full
# identities still distinguish separate remotes that share a basename and SHA.
for dashboard_schema in indexed legacy; do
  (
    CONFIG_FILE="$TEST_ROOT/$dashboard_schema-dashboard-config" WORK_DIR="$TEST_ROOT/$dashboard_schema-dashboard-work" WORK_DIRS="$TEST_ROOT/$dashboard_schema-dashboard-work"
    private_remotes="$TEST_ROOT/home/alice/Customer-X/$dashboard_schema/remotes"
    MIRROR_DIR="$TEST_ROOT/$dashboard_schema-dashboard-mirror" MIRROR_URL="https://$dashboard_schema-dashboard@github.com/fixture/mirror"
    CACHE_DIR="$TEST_ROOT/$dashboard_schema-dashboard-cache" LOG_DIR="$TEST_ROOT/$dashboard_schema-dashboard-logs" MIRROR_EMAIL=mirror@example.test
    for name in first second; do
      git clone --bare --quiet "$TEST_ROOT/remotes/github-source.git" "$private_remotes/$name/project.git"
      git --git-dir="$private_remotes/$name/project.git" symbolic-ref HEAD refs/heads/main
      git clone --quiet --branch main "$private_remotes/$name/project.git" "$WORK_DIR/$name"
    done
    git init --bare --quiet "$TEST_ROOT/remotes/$dashboard_schema-dashboard.git"
    git init --quiet "$MIRROR_DIR"
    git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
    git -C "$MIRROR_DIR" remote add origin "$MIRROR_URL"
    git config --global url."$TEST_ROOT/remotes/$dashboard_schema-dashboard.git".insteadOf "$MIRROR_URL"
    greens_save_config "$CONFIG_FILE" MIRROR_DIR MIRROR_URL CACHE_DIR LOG_DIR MIRROR_EMAIL
    origin="$(git -C "$WORK_DIR/first" config remote.origin.url)"
    if [[ "$dashboard_schema" == indexed ]]; then
      id="$(greens_remote_identity "$origin" 1)"; path="$(greens_remote_path "$id")"
      # Config values are consumed through indexed accessors.
      # shellcheck disable=SC2034
      SOURCE_COUNT=1 SOURCE_1_PROVIDER=git SOURCE_1_API_HOST=file://localhost SOURCE_1_REMOTE_HOSTS=file://localhost SOURCE_1_ORGANIZATION="${path%%/*}" \
        SOURCE_1_USERNAME='' SOURCE_1_EMAILS=author@example.test SOURCE_1_SINCE=2021-01-01 SOURCE_1_ACTIVITY_TYPES=commits SOURCE_1_ACCESS_MODE=remote
      greens_save_config "$CONFIG_FILE" WORK_DIRS SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_API_HOST SOURCE_1_REMOTE_HOSTS SOURCE_1_ORGANIZATION SOURCE_1_USERNAME SOURCE_1_EMAILS SOURCE_1_SINCE SOURCE_1_ACTIVITY_TYPES SOURCE_1_ACCESS_MODE
    else
      # shellcheck disable=SC2034
      SOURCE_PROVIDER=git REMOTE_PREFIX="${origin%first/project.git}" EMAILS=author@example.test SINCE=2021-01-01 ACTIVITY_TYPES=commits
      greens_save_config "$CONFIG_FILE" WORK_DIR SOURCE_PROVIDER REMOTE_PREFIX EMAILS SINCE ACTIVITY_TYPES
    fi
    FIXTURE_VISIBILITY=PRIVATE run_sync
    [[ "$(git -C "$MIRROR_DIR" log --author='<mirror@example.test>' --format=%H | wc -l | tr -d ' ')" == 2 ]] || fail "$dashboard_schema filesystem identities were conflated"
    git --git-dir="$TEST_ROOT/remotes/$dashboard_schema-dashboard.git" show refs/heads/main:README.md > "$TEST_ROOT/$dashboard_schema-published-readme"
    grep -Fq '| project | 2 |' "$TEST_ROOT/$dashboard_schema-published-readme" || fail "$dashboard_schema dashboard omitted display name"
    if grep -Eq 'Customer-X|home/alice' "$TEST_ROOT/$dashboard_schema-published-readme"; then fail "$dashboard_schema dashboard published filesystem hierarchy"; fi
    # Simulate old cached records, then force another published dashboard.
    for cached in "$CACHE_DIR"/activity-state/*/*.jsonl; do
      jq -c '.project="home/alice/Customer-X/remotes/project"' "$cached" > "$cached.old"; mv "$cached.old" "$cached"
    done
    GIT_AUTHOR_DATE=2021-03-01T12:00:00Z GIT_COMMITTER_DATE=2021-03-01T12:00:00Z \
      git -C "$WORK_DIR/first" commit --allow-empty --quiet -m 'new filesystem activity'
    git -C "$WORK_DIR/first" push --quiet origin main
    FIXTURE_VISIBILITY=PRIVATE run_sync
    [[ "$(git -C "$MIRROR_DIR" log --author='<mirror@example.test>' --format=%H | wc -l | tr -d ' ')" == 3 ]] || fail "$dashboard_schema cache migration replayed filesystem activity"
    git --git-dir="$TEST_ROOT/remotes/$dashboard_schema-dashboard.git" show refs/heads/main:README.md > "$TEST_ROOT/$dashboard_schema-published-readme"
    grep -Fq '| project | 3 |' "$TEST_ROOT/$dashboard_schema-published-readme" || fail "$dashboard_schema cached display names were not normalized"
    if grep -Eq 'Customer-X|home/alice' "$TEST_ROOT/$dashboard_schema-published-readme"; then fail "$dashboard_schema cached hierarchy was published"; fi
    jq -es 'all(.[]; (.key|startswith("file://")) and (.key|contains("Customer-X")))' "$CACHE_DIR"/activity-state/*/*.jsonl >/dev/null || fail "$dashboard_schema filesystem identity lost its full path"
  ) || fail "$dashboard_schema filesystem dashboard privacy"
done
echo "PASS: indexed and legacy private dashboards redact filesystem hierarchy, including cached records"

# API-enabled GitLab commit identity survives renames and activity-selection
# changes. Upgrade aliases must verify IDs, preserving distinct fork projects.
(
  CONFIG_FILE="$TEST_ROOT/gitlab-rename-config" WORK_DIRS="$TEST_ROOT/gitlab-rename-work" SCAN_MODE=in-root SOURCE_COUNT=1
  MIRROR_DIR="$TEST_ROOT/gitlab-rename-mirror" MIRROR_URL=https://rename-fixture@github.com/fixture/mirror
  CACHE_DIR="$TEST_ROOT/gitlab-rename-cache" LOG_DIR="$TEST_ROOT/gitlab-rename-logs" MIRROR_EMAIL=mirror@example.test
  # Values are consumed by indexed accessors and greens_save_config.
  # shellcheck disable=SC2034
  SOURCE_1_PROVIDER=gitlab SOURCE_1_API_HOST=forge.example SOURCE_1_REMOTE_HOSTS=forge.example SOURCE_1_ORGANIZATION=team SOURCE_1_USERNAME=fixture \
    SOURCE_1_EMAILS=author@example.test SOURCE_1_SINCE=2021-01-01 SOURCE_1_ACTIVITY_TYPES=commits,issues SOURCE_1_ACCESS_MODE=remote
  git clone --quiet "$TEST_ROOT/remotes/github-source.git" "$WORK_DIRS/repo"
  sha="$(git --git-dir="$TEST_ROOT/remotes/github-source.git" rev-parse refs/heads/main)"
  for path in old new third fork; do git config --global --add url."$TEST_ROOT/remotes/github-source.git".insteadOf "git@forge.example:team/$path.git"; done
  git -C "$WORK_DIRS/repo" remote set-url origin git@forge.example:team/old.git
  git init --bare --quiet "$TEST_ROOT/remotes/gitlab-rename-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$MIRROR_URL"
  git config --global url."$TEST_ROOT/remotes/gitlab-rename-mirror.git".insteadOf "$MIRROR_URL"
  greens_save_config "$CONFIG_FILE" WORK_DIRS SCAN_MODE SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_API_HOST SOURCE_1_REMOTE_HOSTS SOURCE_1_ORGANIZATION SOURCE_1_USERNAME SOURCE_1_EMAILS SOURCE_1_SINCE SOURCE_1_ACTIVITY_TYPES SOURCE_1_ACCESS_MODE MIRROR_DIR MIRROR_URL CACHE_DIR LOG_DIR MIRROR_EMAIL
  touch "$TEST_ROOT/rename-fixture"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  first_tip="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 1 ]] || fail "GitLab ID fixture activity count"
  stable_key="forge.example/7/commit/$sha"
  git -C "$MIRROR_DIR" log --format=%B | grep -q "$(printf '%s' "$stable_key" | greens_hash)" || fail "GitLab commit key did not use project ID"
  git -C "$WORK_DIRS/repo" remote set-url origin git@forge.example:team/new.git
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$first_tip" ]] || fail "GitLab rename replayed unchanged commits"
  SOURCE_1_ACTIVITY_TYPES=commits; greens_save_config "$CONFIG_FILE" SOURCE_1_ACTIVITY_TYPES
  rm -f "$TEST_ROOT/glab-called"; touch "$TEST_ROOT/forbid-glab"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  rm "$TEST_ROOT/forbid-glab"
  [[ ! -e "$TEST_ROOT/glab-called" && "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$first_tip" ]] || fail "commits-only switch lost verified GitLab project ID"
  # Recreate a pre-ID marker/cache, then rename before its first fixed sync.
  old_key="forge.example/team/old/commit/$sha"
  GIT_AUTHOR_DATE=2021-02-03T12:30:00Z GIT_COMMITTER_DATE=2021-02-03T12:30:00Z \
    git -C "$MIRROR_DIR" commit --amend --allow-empty --quiet -m "$(printf 'sync\n\nGreens-Activity: %s' "$(printf '%s' "$old_key" | greens_hash)")"
  git -C "$MIRROR_DIR" push --force --quiet origin HEAD:refs/heads/main
  old_path_key="$(printf '%s' forge.example/team/old | greens_hash)"
  for cached in "$CACHE_DIR"/activity-state/*/"$old_path_key.jsonl"; do
    [[ -f "$cached" ]] || continue
    jq -c --arg key "$old_key" 'if .kind=="commits" then .key=$key else . end' "$cached" > "$cached.old"; mv "$cached.old" "$cached"
  done
  rm -rf "$CACHE_DIR/gitlab-projects"
  # shellcheck disable=SC2034
  SOURCE_1_ACTIVITY_TYPES=commits,issues; greens_save_config "$CONFIG_FILE" SOURCE_1_ACTIVITY_TYPES
  git -C "$WORK_DIRS/repo" remote set-url origin git@forge.example:team/third.git
  legacy_tip="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$legacy_tip" ]] || fail "pre-ID rename duplicated the old-path marker"
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$legacy_tip" ]] || fail "GitLab marker upgrade was not idempotent"
  git -C "$WORK_DIRS/repo" remote set-url origin git@forge.example:team/fork.git
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 2 ]] || fail "distinct GitLab project sharing a SHA was suppressed"
  # Recreating a path with a new ID must not import its previous cached data
  # into a fresh destination using the same config and source cache.
  touch "$TEST_ROOT/recreated-project"
  MIRROR_DIR="$TEST_ROOT/recreated-project-mirror" MIRROR_URL=https://recreated-project@github.com/fixture/mirror
  git init --bare --quiet "$TEST_ROOT/remotes/recreated-project-mirror.git"
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$MIRROR_URL"
  git config --global url."$TEST_ROOT/remotes/recreated-project-mirror.git".insteadOf "$MIRROR_URL"
  greens_save_config "$CONFIG_FILE" MIRROR_DIR MIRROR_URL
  FIXTURE_VISIBILITY=PUBLIC run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 1 ]] || fail "recreated project imported previous project ID activity"
  rm "$TEST_ROOT/recreated-project"
  rm "$TEST_ROOT/rename-fixture"
) || fail "stable GitLab project commit identities"
echo "PASS: GitLab project renames, pre-ID markers, commits-only transitions and distinct fork histories"

# A replacement at the same path needs a full API backfill, even though its
# activity settings/features are unchanged and the old checkpoint is recent.
for schema in indexed legacy; do
  (
    CONFIG_FILE="$TEST_ROOT/$schema-checkpoint-config" WORK_DIR="$TEST_ROOT/$schema-checkpoint-work" WORK_DIRS="$TEST_ROOT/$schema-checkpoint-work"
    MIRROR_DIR="$TEST_ROOT/$schema-checkpoint-mirror" MIRROR_URL="https://$schema-checkpoint@github.com/fixture/mirror"
    CACHE_DIR="$TEST_ROOT/$schema-checkpoint-cache" LOG_DIR="$TEST_ROOT/$schema-checkpoint-logs" MIRROR_EMAIL=mirror@example.test
    git init --quiet "$WORK_DIR/repo"
    git -C "$WORK_DIR/repo" remote add origin git@forge.example:team/checkpoint.git
    git init --bare --quiet "$TEST_ROOT/remotes/$schema-checkpoint.git"
    git init --quiet "$MIRROR_DIR"
    git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
    git -C "$MIRROR_DIR" remote add origin "$MIRROR_URL"
    git config --global url."$TEST_ROOT/remotes/$schema-checkpoint.git".insteadOf "$MIRROR_URL"
    greens_save_config "$CONFIG_FILE" MIRROR_DIR MIRROR_URL CACHE_DIR LOG_DIR MIRROR_EMAIL
    if [[ "$schema" == indexed ]]; then
      # Config values are read through indexed accessors.
      # shellcheck disable=SC2034
      SOURCE_COUNT=1 SOURCE_1_PROVIDER=gitlab SOURCE_1_API_HOST=forge.example SOURCE_1_REMOTE_HOSTS=forge.example SOURCE_1_ORGANIZATION=team \
        SOURCE_1_USERNAME=fixture SOURCE_1_EMAILS=author@example.test SOURCE_1_SINCE=2021-01-01 SOURCE_1_ACTIVITY_TYPES=issues,comments SOURCE_1_ACCESS_MODE=remote
      greens_save_config "$CONFIG_FILE" WORK_DIRS SOURCE_COUNT SOURCE_1_PROVIDER SOURCE_1_API_HOST SOURCE_1_REMOTE_HOSTS SOURCE_1_ORGANIZATION SOURCE_1_USERNAME SOURCE_1_EMAILS SOURCE_1_SINCE SOURCE_1_ACTIVITY_TYPES SOURCE_1_ACCESS_MODE
    else
      # shellcheck disable=SC2034
      SOURCE_PROVIDER=gitlab GITLAB_HOST=forge.example GITLAB_USERNAME=fixture EMAILS=author@example.test SINCE=2021-01-01 ACTIVITY_TYPES=issues,comments
      greens_save_config "$CONFIG_FILE" WORK_DIR SOURCE_PROVIDER GITLAB_HOST GITLAB_USERNAME EMAILS SINCE ACTIVITY_TYPES
    fi
    # SINCE is local midnight, so its UTC form depends on the timezone running the tests.
    export FIXTURE_SINCE_UTC; FIXTURE_SINCE_UTC="$(greens_utc_date "$(greens_epoch 2021-01-01)")"
    touch "$TEST_ROOT/project-checkpoint-fixture"
    FIXTURE_VISIBILITY=PUBLIC run_sync
    [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 2 ]] || fail "$schema initial issue/discussion collection"
    checkpoint_before="$(cat "$CACHE_DIR"/activity-state/*/*.checkpoint)"
    id_before="$(cat "$CACHE_DIR"/gitlab-projects/*/*.id)"
    touch "$TEST_ROOT/checkpoint-replacement"
    printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/remotes/$schema-checkpoint.git/hooks/pre-receive"
    chmod +x "$TEST_ROOT/remotes/$schema-checkpoint.git/hooks/pre-receive"
    if FIXTURE_VISIBILITY=PUBLIC run_sync; then fail "$schema replacement skipped backfill/push rejection"; fi
    [[ "$(cat "$CACHE_DIR"/activity-state/*/*.checkpoint)" == "$checkpoint_before" && "$(cat "$CACHE_DIR"/gitlab-projects/*/*.id)" == "$id_before" ]] || fail "$schema failed replacement published checkpoint/project ID"
    rm "$TEST_ROOT/remotes/$schema-checkpoint.git/hooks/pre-receive"
    FIXTURE_VISIBILITY=PUBLIC run_sync
    [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 4 ]] || fail "$schema replacement omitted historical issue/discussion"
    [[ "$(cat "$CACHE_DIR"/gitlab-projects/*/*.id)" == 18 ]] || fail "$schema replacement ID was not published"
    FIXTURE_VISIBILITY=PUBLIC run_sync
    [[ "$(git -C "$MIRROR_DIR" rev-list --count HEAD)" == 4 ]] || fail "$schema replacement rerun duplicated activity"
    rm "$TEST_ROOT/project-checkpoint-fixture" "$TEST_ROOT/checkpoint-replacement"
  ) || fail "$schema project checkpoint invalidation"
done
echo "PASS: project replacements backfill historical issues/discussions and retain transactional checkpoints in both schemas"

# The real legacy collector may have copied acknowledged source subjects.
# Setup disables future copying without recreating those existing activities.
(
  CONFIG_FILE="$TEST_ROOT/copied-message-config" WORK_DIR="$TEST_ROOT/copied-message-work"
  REMOTE_PREFIX="$TEST_ROOT/filesystem remotes %/"
  MIRROR_DIR="$TEST_ROOT/copied-message-mirror" MIRROR_URL=https://copied-mode@github.com/fixture/mirror
  CACHE_DIR="$TEST_ROOT/copied-message-cache" LOG_DIR="$TEST_ROOT/copied-message-logs"
  SOURCE_PROVIDER=github EMAILS=author@example.test MIRROR_EMAIL=mirror@example.test MIRROR_NAME=greens
  # Values are consumed by name in greens_save_config.
  # shellcheck disable=SC2034
  PERSONAL_GH_USER=fixture GITHUB_USERNAME=fixture ACTIVITY_TYPES=commits SINCE='2021-01-01 00:00:00'
  # shellcheck disable=SC2034
  COPY_MESSAGES=1 COPY_MESSAGES_ACK=1 SCHEDULER=manual SYNC_HOUR=0
  git clone --quiet "$TEST_ROOT/filesystem remotes %/source-1.git" "$WORK_DIR/repo"
  GIT_AUTHOR_DATE=2021-01-01T12:00:00Z GIT_COMMITTER_DATE=2021-01-01T12:00:00Z \
    git -C "$WORK_DIR/repo" commit --amend --allow-empty --quiet -m init
  git clone --bare --quiet "$WORK_DIR/repo" "$TEST_ROOT/filesystem remotes %/copied-init.git"
  git -C "$WORK_DIR/repo" remote set-url origin "$TEST_ROOT/filesystem remotes %/copied-init.git"
  git init --bare --quiet "$TEST_ROOT/remotes/copied-message-mirror.git"
  git --git-dir="$TEST_ROOT/remotes/copied-message-mirror.git" symbolic-ref HEAD refs/heads/main
  git init --quiet "$MIRROR_DIR"
  git -C "$MIRROR_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR_DIR" remote add origin "$MIRROR_URL"
  git config --global url."$TEST_ROOT/remotes/copied-message-mirror.git".insteadOf "$MIRROR_URL"
  greens_save_config "$CONFIG_FILE" SOURCE_PROVIDER WORK_DIR REMOTE_PREFIX MIRROR_DIR MIRROR_URL CACHE_DIR LOG_DIR EMAILS MIRROR_EMAIL MIRROR_NAME PERSONAL_GH_USER GITHUB_USERNAME ACTIVITY_TYPES SINCE COPY_MESSAGES COPY_MESSAGES_ACK SCHEDULER SYNC_HOUR
  run_sync
  [[ "$(git -C "$MIRROR_DIR" log --format=%s --author='<mirror@example.test>')" == init ]] || fail "legacy collector did not copy root init subject"
  old_tip="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  {
    printf 'y\n'
    printf '\n%.0s' {1..11}
    printf 'y\n'
  } | CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/setup.sh" > "$TEST_ROOT/copied-message-setup-output" 2>&1 || {
    cat "$TEST_ROOT/copied-message-setup-output"; fail "copied-message legacy migration";
  }
  if grep -q 'Initial sync failed' "$TEST_ROOT/copied-message-setup-output"; then cat "$TEST_ROOT/copied-message-setup-output"; fail "initial copied-message sync"; fi
  bash -c 'source "$1"; [[ "$SOURCE_COUNT" == 1 && "$COPY_MESSAGES" == 0 && "$COPY_MESSAGES_ACK" == 0 && "$GREENS_LEGACY_TIMESTAMPS" == 1 && "$GREENS_LEGACY_COPIED_MESSAGES" == 1 ]]' bash "$CONFIG_FILE" || fail "copied-message migration did not retain its root activity mode"
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$old_tip" ]] || fail "migration recreated an activity with a copied subject"
  run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$old_tip" ]] || fail "fresh sync duplicated copied-message activity"
  {
    printf 'y\n'
    printf '\n%.0s' {1..11}
    printf 'n\n'
  } | CONTRIB_MIRROR_CONFIG="$CONFIG_FILE" bash "$ROOT/setup.sh" > "$TEST_ROOT/copied-message-rerun-output" 2>&1 || {
    cat "$TEST_ROOT/copied-message-rerun-output"; fail "copied root setup rerun";
  }
  run_sync
  [[ "$(git -C "$MIRROR_DIR" rev-parse HEAD)" == "$old_tip" ]] || fail "setup rerun lost copied root init activity"
) || fail "acknowledged copied-message migration regression"
echo "PASS: legacy copied-message collector migrates without duplicating existing activity"

# Keep native Windows drive/UNC identities compatible with their file URIs.
(
  cygpath() {
    case "$2" in
      C:/*) printf '%s\n' "$2" ;;
      //SERVER/share/*) printf '%s\n' "$2" ;;
      *) return 1 ;;
    esac
  }
  [[ "$(greens_remote_identity 'C:/Users/Work/repo.git' 1)" == 'file:///C:/Users/Work/repo.git' ]] || fail "Windows drive file identity"
  [[ "$(greens_remote_identity 'file:///C:/Users/Work/repo.git' 1)" == 'file:///C:/Users/Work/repo.git' ]] || fail "Windows file URI was converted as a POSIX mount"
  [[ "$(greens_remote_identity '//SERVER/share/repo.git' 1)" == 'file://server/share/repo.git' ]] || fail "Windows UNC file identity"
) || fail "Windows filesystem identity normalization"

[[ ! -f "$TEST_ROOT/forbidden-switches" ]] || fail "provider commands changed shared gh authentication"
