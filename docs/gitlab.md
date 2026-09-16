# GitLab and Linux support

## Setup

Use a current Git, Bash (including macOS Bash 3.2), jq, and GitHub CLI. GitLab
API activity additionally requires glab. Network operations use GNU timeout
when available, otherwise Perl. GitLab.com and any number of self-managed
GitLab hosts can coexist with GitHub sources in one configuration.

Authenticate with the normal CLI credential stores:

    gh auth login
    glab auth login --hostname gitlab.example.com
    greens --setup

Setup discovers GitLab repositories automatically, then asks for each detected
host and top-level namespace:

1. One or more parent directories containing source clones/worktrees.
2. The GitLab API domain when a Git remote uses an unknown host or SSH alias.
3. The authenticated GitLab username, exact author emails, activity types, and
   history start for that host/namespace.
4. Your GitHub destination account, verified attribution email, and mirror URL.
5. A local mirror directory outside every source tree and the daily schedule.

Suggestions are editable; nothing personal is compiled into the scripts.
Setup can create a private mirror or use an existing empty repository.
It discovers the GitHub default branch, including on empty repositories.
The mirror identity is generic by default. Enable **Include private contributions**
on your GitHub profile to make private contribution counts visible.

For commit-only operation without a GitLab API session, classify a host as
**generic Git**. See the [mixed-provider guide](sources.md) for the indexed
configuration format, automatic detection, rerun behavior, and migration.

If Git or GitLab API access is unavailable, setup can save the complete
host/namespace group as local-only. No `glab` call or Git fetch is made for a
saved local group. Greens scans every ref already present in matching working
copies, including unpushed commits, and deduplicates duplicate clones. Merge
requests, issues, comments, approvals, merges, and state changes cannot be
reconstructed from local Git history.

The GitLab actor must match the authenticated glab account. Use a token with
access to the selected projects and the API endpoints below (the api scope
supports all required calls). Source Git access uses your existing SSH/HTTPS
credentials. The destination uses your normal GitHub Git credentials.
Setup does not copy glab credentials into its configuration.

## Activity semantics

| Type | Source and timestamp |
|---|---|
| commits | Commits matching a configured author email; original author timestamp |
| mrs | Merge requests opened by the actor; object creation timestamp |
| issues | Issues opened by the actor; object creation timestamp |
| comments | Non-system issue/MR discussion notes, including diff reviews; note creation timestamp |
| approvals | Actor's approval/unapproval events in GitLab's user activity feed |
| merges | Actor's merge-request merge state events |
| state_changes | Actor's issue/MR close/reopen state events |

Each GitLab host/namespace defaults to all seven types and can be configured
independently. GitHub's `prs` and `reviews` names are not GitLab option names.

Only projects discovered under the configured directories and matching a saved
host/namespace record are queried.
Discovery recognizes .git files and directories at the configured scan depth and deduplicates
SSH/HTTPS clones and worktrees by host/project. Separate bare caches fetch
branches, tags, and available merge-request head refs; working clones are never
fetched, checked out, or modified. In remote mode, unpushed local commits are
not included.
Push events are not counted again on top of individual commits.

Pagination is exhaustive. Issue/MR resources and discussions provide activity
that the user event feed may omit. API timestamps are UTC; Git timestamps retain
their original timezone. Fractional seconds are truncated to Git's precision,
while distinct activities in the same second remain separate.

Each activity becomes a generic synthetic commit with an opaque SHA-256
Greens-Activity trailer derived from its source identity. Raw object IDs,
repository URLs, titles, comments, and source files are not published in those
commits. The existing dashboard lists repository names only when the mirror is
verified private. Raw message copying is unsupported by the new providers.

### Historical limits

Deleted objects/notes, expired activity events, and unreachable commits cannot
always be recovered. Approval history depends on GitLab's event retention and
endpoint support; some versions omit MR events from the user feed, so approval
coverage is best-effort. See the [GitLab Events API limitations](https://docs.gitlab.com/api/events/).
Project membership, branch deletion, CI runs, and arbitrary
edits are not separate contributions. Counts therefore need not equal GitLab's
contribution calendar. No timestamp is inferred from an object's updated_at.

Normalized activity records are retained locally, so activities already
collected remain mirrored after their source branch or object disappears.
Incremental queries overlap the previous successful run by one day. Changing
the history start or selected types triggers a fresh API scan for that project.
Newly discovered projects receive the full configured backfill.

## Configuration and compatibility

Setup writes safely shell-escaped defaults to ~/.contrib-mirror/config with
owner-only permissions. Re-running setup first shows a redacted summary and,
after confirmation, offers saved values as defaults. Environment variables take
precedence; an alternate file works with both commands:

    CONTRIB_MIRROR_CONFIG="$HOME/.config/greens/work" greens --setup
    CONTRIB_MIRROR_CONFIG="$HOME/.config/greens/work" greens sync

See the README configuration table for keys. This is a shell config, not a
dotenv parser; use setup instead of placing untrusted shell text in the file.
Keep it and all caches outside version control.

Legacy `SOURCE_PROVIDER=gitlab` and Git-only configurations continue to work.
Completing the new setup converts managed legacy keys to `WORK_DIRS` and indexed
source records. Existing greens timestamp history is used as a compatibility
baseline, and new activities use stable IDs. Automatic resync/force-push remains
unavailable for indexed or GitLab sources; privacy migration preserves IDs.

Ordinary sync is append-only. Selecting fewer types or a later cutoff does not
delete previously mirrored contributions. Keep one configuration per mirror.

## Linux scheduling

The installer uses ~/.local/bin on Linux. To install the checkout you are
developing instead of downloading the upstream source:

    bash install.sh --local

Keep that checkout in place; the executable is a symlink. GREENS_BIN_DIR can
select a different executable directory.

Setup offers systemd user timers, cron, and manual execution. The systemd unit
name contains a hash of the config path, allowing separate configurations.
The timer runs at the selected hour in the system's local timezone and uses
Persistent=true to catch missed runs when the user manager starts, normally
at login. It does not wake a powered-off computer or enable login lingering.
Failures retry after 15 minutes. CLI paths are captured during setup, including
snap installations; rerun setup after moving executables.

Inspect the unit name with:

    greens --status
    systemctl --user list-timers 'greens-*'
    journalctl --user -u '<unit-name>.service'

Rerun setup to change the schedule or select manual mode. greens --reset offers
removal of that configuration's scheduler. Cron skips missed runs and writes
to the configured log directory. SSH access must work without interactive
prompts; use your session's SSH agent or existing noninteractive credentials.

## Failures and recovery

- **Authentication failure:** authenticate gh/glab for the configured accounts;
  verify SSH/HTTPS source access, or run greens interactively and confirm the
  offered local-only fallback. CLI tokens are never printed by greens.
- **Partial collection or rejected push:** the run fails without advancing
  checkpoints. Retry with FORCE=1 if a previous successful run occurred today.
  Pending local commits and their IDs prevent duplicate contributions.
- **Dirty or diverged mirror:** resolve its local state first. Normal sync does
  not force-push or discard local files.
- **Missing contributions:** check author emails, project discovery, selected
  types, cutoff, and historical limits. GitHub attribution requires an associated
  email and commits on the repository's default branch.
- **Wrong scheduler executable/credentials:** rerun setup in the intended user
  session, then start the service manually and inspect its journal.

## Development and packaging

Run the offline integration tests with:

    bash tests/providers.sh

CI runs these fixtures on Ubuntu and macOS alongside the existing platform
tests. Fixtures use only example hosts/accounts and local bare remotes.
They require no service credentials.

Distributions must install the **lib directory alongside sync.sh and setup.sh**.
Keep that layout in Homebrew/libexec and other packaging; copying only the two
entrypoint scripts is insufficient. Local installation and the standard Git
clone installer preserve the full layout.
