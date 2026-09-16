# Source discovery and mixed providers

## Setup flow

`greens --setup` accepts any number of repository roots. Paths are canonicalized,
stored in `WORK_DIRS`, and scanned recursively for Git repositories and
worktrees. Overlapping roots, duplicate clones, and SSH/HTTPS forms of the same
repository are deduplicated before activity is collected.

Repositories are grouped by provider, API host, and organization. A GitHub
organization is the repository owner. A GitLab organization is the top-level
namespace, so `group/platform/service` belongs to `group`. Every group has its
own username, commit emails, history start, and activity selection.

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

## Configuration schema

The configuration is an owner-only Bash environment file. Use setup to edit it;
the example below documents its shape:

```bash
WORK_DIRS=$'/srv/work\n/home/me/projects'
SOURCE_COUNT=2

SOURCE_1_PROVIDER=github
SOURCE_1_REMOTE_HOSTS=github.com,github-work
SOURCE_1_API_HOST=github.com
SOURCE_1_ORGANIZATION=example-inc
SOURCE_1_USERNAME=developer
SOURCE_1_EMAILS=developer@example.com
SOURCE_1_SINCE=2026-01-01
SOURCE_1_ACTIVITY_TYPES=commits,prs,issues

SOURCE_2_PROVIDER=gitlab
SOURCE_2_REMOTE_HOSTS=gitlab.internal,company-git
SOURCE_2_API_HOST=gitlab.internal
SOURCE_2_ORGANIZATION=platform
SOURCE_2_USERNAME=developer
SOURCE_2_EMAILS=developer@example.com,developer@users.noreply.example.com
SOURCE_2_SINCE='2025-07-01 00:00:00'
SOURCE_2_ACTIVITY_TYPES=commits,mrs,issues,comments,approvals,merges,state_changes
```

`SOURCE_N_REMOTE_HOSTS` contains the hostnames that may appear in Git remote
URLs. `SOURCE_N_API_HOST` is the canonical web/API domain passed explicitly to
`gh` or `glab`. Environment variables can override any saved value.

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

Changing a source's activity types, emails, or history start gives it an
isolated state namespace. Normal sync remains append-only: narrowing settings
does not remove commits already published to the mirror.

## Rerunning setup and migration

When setup finds a configuration, it first prints a redacted summary and asks
whether to rerun. The default is to leave it unchanged. If continued, existing
roots and matching source records become prompt defaults. Missing roots and
sources are shown but are not silently deleted.

Legacy configurations remain valid:

- `WORK_DIR` is treated as one repository root.
- Missing `SOURCE_PROVIDER` still means the original GitHub provider.
- Explicit legacy `SOURCE_PROVIDER=gitlab` and `SOURCE_PROVIDER=git` retain their
  existing behavior.
- `REMOTE_PREFIX`, `GITHUB_*`, `GITLAB_*`, global `EMAILS`, `SINCE`, and
  `ACTIVITY_TYPES` are read exactly as before.

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
- **A directory is temporarily unavailable:** keep it during setup. Sync warns
  and continues scanning other configured roots.
- **Settings changed but sync already ran today:** use `FORCE=1 greens`.
