# Source discovery and mixed providers

## Setup flow

`greens --setup` accepts any number of repository roots. Paths are canonicalized,
stored in `WORK_DIRS`, and scanned in the configured mode for Git repositories and
worktrees. Checkouts whose normalized `origin` identifies the same repository,
including SSH/HTTPS forms and overlapping roots, are counted and processed once.
Setup asks for one
root at a time and repeats the prompt until an empty answer is submitted.
On a rerun, saved roots are retained automatically and the first directory
prompt adds another root.

The default `SCAN_MODE=recursive` searches every descendant. Running setup with
`--in-root` persists `SCAN_MODE=in-root`: only `.git` files or directories in
immediate child folders of each work root are inspected. The work root itself
and deeper descendants are ignored by setup, status, and sync. Rerunning setup
without a scan flag retains the saved mode; `--recursive` explicitly restores
recursive discovery.

Repositories are grouped by provider, API host, and organization. A GitHub
organization is the repository owner. A GitLab organization is the top-level
namespace, so `group/platform/service` belongs to `group`. Every group has its
own username, commit emails, history start, and activity selection.
Entering `-` at its author-email prompt skips the complete group before account
or activity configuration. All repositories represented by that group are
omitted from sync. The group is offered again on a later setup run.

Known `github.com` and `gitlab.com` remotes are classified without a network
probe. For another remote host, setup asks for the web/API domain. This matters
for SSH aliases such as `github-work` or `company-git`. Setup then tries:

1. An authenticated GitHub CLI request for that domain.
2. An authenticated GitLab CLI request for that domain.
3. Short HTTPS requests to the GitHub Enterprise API root and GitLab metadata
   endpoint, accepting only recognizable JSON responses.
4. Manual GitHub, GitLab, generic Git, or ignore selection if detection remains
   inconclusive.

TLS verification is never disabled. A private CA or unreachable instance falls
back to manual classification instead of being trusted from its HTML branding.

Before saving, setup prints the selected directories and source groups. It
writes the complete configuration atomically only after validation. Tokens stay
in the normal `gh` and `glab` credential stores.

Each GitHub owner has its own configured account, while the destination has a
separate personal-account setting. There is no separate-account question: the
selected usernames already provide that information. API calls temporarily
select the source account with `gh`, then restore the previously active account.
The personal destination username and primary verified email are pre-filled
from the authenticated personal `github.com` account.

## Configuration schema

The configuration is an owner-only Bash environment file. Use setup to edit it;
the example below documents its shape:

```bash
WORK_DIRS=$'/srv/work\n/home/me/projects'
SCAN_MODE=recursive
SOURCE_COUNT=2

SOURCE_1_PROVIDER=github
SOURCE_1_REMOTE_HOSTS=github.com,github-work
SOURCE_1_API_HOST=github.com
SOURCE_1_ORGANIZATION=example-inc
SOURCE_1_USERNAME=developer
SOURCE_1_EMAILS=developer@example.com
SOURCE_1_SINCE=2026-01-01
SOURCE_1_ACTIVITY_TYPES=commits,prs,issues
SOURCE_1_ACCESS_MODE=remote

SOURCE_2_PROVIDER=gitlab
SOURCE_2_REMOTE_HOSTS=gitlab.internal,company-git
SOURCE_2_API_HOST=gitlab.internal
SOURCE_2_ORGANIZATION=platform
SOURCE_2_USERNAME=developer
SOURCE_2_EMAILS=developer@example.com,developer@users.noreply.example.com
SOURCE_2_SINCE='2025-07-01 00:00:00'
SOURCE_2_ACTIVITY_TYPES=commits,mrs,issues,comments,approvals,merges,state_changes
SOURCE_2_ACCESS_MODE=local
```

`SOURCE_N_REMOTE_HOSTS` contains the hostnames that may appear in Git remote
URLs. `SOURCE_N_API_HOST` is the canonical web/API domain passed explicitly to
`gh` or `glab`. Environment variables can override any saved value.

`SOURCE_N_ACCESS_MODE` defaults to `remote`. A `local` source is restricted to
`commits`, reads `git log --all` from every matching checkout, combines duplicate
clones, and makes no Git or provider request to the source host. This includes
unpushed commits and is limited to objects and refs retained locally.

Provider activity names are deliberately separate:

| Provider | Values |
|---|---|
| GitHub | `commits`, `prs`, `issues`, `reviews` |
| GitLab | `commits`, `mrs`, `issues`, `comments`, `approvals`, `merges`, `state_changes` |
| Generic Git | `commits` |

GitHub reviews remain opt-in because the available search timestamp is the pull
request update time, which can move after a review. Generic Git has no API
activity. `COPY_MESSAGES` remains global and is disabled for the indexed mixed
provider format so source titles and commit subjects do not leak.

## Sync behavior

Every discovered repository is matched to exactly one indexed source by remote
host and organization. Commits are fetched into bare caches; working checkouts
are never fetched, switched, or modified. GitLab merge-request refs are included
when available. API calls always name their configured host explicitly.

Activities from all sources are normalized, sorted, and deduplicated before one
mirror transaction. Synthetic commits contain only the timestamp and an opaque
`Greens-Activity` identifier. If any configured source, destination push, or
checkpoint publication fails, the run fails and unpublished checkpoints remain
unchanged. A retry reuses stable identifiers and cannot duplicate successful
activity.

Remote groups are checked before collection starts. In an interactive terminal,
a failed Git or required provider API check offers to atomically save the whole
host/organization group as local-only and continue. Declining aborts without
changing checkpoints. Systemd and cron runs cannot confirm the change, so they
fail and instruct the user to run `greens` interactively.

Changing a source's activity types, emails, or history start gives it an
isolated state namespace. Normal sync remains append-only: narrowing settings
does not remove commits already published to the mirror.

## Rerunning setup and migration

When setup finds a configuration, it first prints a redacted summary and asks
whether to rerun. The default is to leave it unchanged. If continued, existing
roots and matching source records become prompt defaults. Missing roots and
sources are shown but are not silently deleted.

Saved roots are numbered during a rerun and can be removed before adding new
ones. The equivalent repeatable flag is `--remove-work-dir PATH` after `--setup`
or `init`, or when invoking `setup.sh` directly. Explicit CLI removal implies
rerunning setup. Source groups found only below removed roots are dropped; setup
aborts without saving if a retained root is unavailable or no replacement is
provided for the last root.

Legacy configurations remain valid:

- `WORK_DIR` is treated as one repository root.
- Missing `SOURCE_PROVIDER` still means the original GitHub provider.
- Explicit legacy `SOURCE_PROVIDER=gitlab` and `SOURCE_PROVIDER=git` retain their
  existing behavior.
- `REMOTE_PREFIX`, `GITHUB_*`, `GITLAB_*`, global `EMAILS`, `SINCE`, and
  `ACTIVITY_TYPES` are read exactly as before.
- When a legacy GitHub activity list is applied to a GitLab source, `prs` is
  converted to GitLab's corresponding `mrs` activity name.

Completing setup migrates those managed values to `WORK_DIRS` and indexed
sources, while preserving unrelated custom lines. Existing greens-generated
timestamp history is recognized during the transition so activities are not
recreated; all new activities receive stable identifiers. Foreign destination
history is still refused.

## Troubleshooting

- **A repository is absent:** verify its `origin`, work root, remote alias, and
  top-level organization in `greens --status`.
- **Provider detection fails:** enter the real HTTPS domain rather than an SSH
  alias, verify its CA trust, or select the provider manually.
- **Authentication fails:** run `gh auth login --hostname HOST` or
  `glab auth login --hostname HOST`, then rerun setup so the saved actor matches.
- **A different GitHub account is active:** no manual switch is required during
  sync; authenticate the saved account once and greens selects it per source.
- **A directory is temporarily unavailable:** keep it during setup. Sync warns
  and continues scanning other configured roots.
- **Settings changed but sync already ran today:** use `FORCE=1 greens`.
