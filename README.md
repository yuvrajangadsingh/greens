# greens

Your work is real. Your contribution graph should show it.

If you commit to private/org repos all day but your GitHub profile looks empty, greens fixes that. It mirrors commit timestamps (and optionally PRs, reviews, issues) to a public repo without exposing any code.

<p align="center">
  <img src="assets/demo.svg" alt="greens demo" width="600">
</p>

> Windows 10/11 support is in beta in v1.8.0. If you try it on a real machine, please share results in [Discussions](https://github.com/yuvrajangadsingh/greens/discussions) for reports and [Issues](https://github.com/yuvrajangadsingh/greens/issues) for bugs.

## Install

### macOS

```bash
brew install yuvrajangadsingh/greens/greens
```

### Windows (10/11)

Requires [Git for Windows](https://git-scm.com/download/win) (includes Git Bash).

```
git clone https://github.com/yuvrajangadsingh/greens.git
cd greens
greens.cmd
```

The setup wizard runs on first use and offers Windows Task Scheduler for daily automation.

> **Note:** Unlike launchd on macOS, Windows Task Scheduler does not catch up on missed runs. If your machine was off or sleeping at the scheduled time, the sync is skipped until the next day. Logs are written to `~/.contrib-mirror/logs/sync.log`.

> **WSL users:** Use the macOS/Linux instructions inside WSL. Don't run both WSL and Windows setups, they'll create duplicate commits.

> **SSH keys:** If your SSH key has a passphrase, the scheduled task may fail silently. Use a passphrase-less key or configure ssh-agent to start at Windows login.

<details>
<summary>Manual install (any OS)</summary>

```bash
git clone https://github.com/yuvrajangadsingh/greens.git
cd greens
bash setup.sh
```

</details>

Then just run `greens` (macOS/Linux) or `greens.cmd` (Windows). Setup wizard runs on first use.

## What it does

1. Scans your work repos (never modifies them)
2. Extracts commit timestamps for your email(s) across all branches
3. Optionally fetches PR/issue timestamps via GitHub API
4. Creates empty commits with matching timestamps in a mirror repo, authored with a generic name and your personal email
5. On a **verified-private** mirror, writes a dashboard README showing which repos your activity came from (visible only to people with access to that private repo)
6. Pushes to your mirror repo (private by default)

No source code, file paths, branch names, or messages ever leave your machine (messages only if you explicitly opt in to copying commit subjects). Work repo **names** appear in exactly one place — the dashboard README — and that is only written while the mirror is positively verified private via the GitHub CLI. Public or unverifiable mirrors get empty commits and nothing else.

**Works with any git remote.** Your source repos can be on GitHub, GitLab, Bitbucket, or self-hosted. greens scans the local clone, not the remote. The mirror destination is GitHub (GitLab/Bitbucket mirror support is [planned](https://github.com/yuvrajangadsingh/greens/issues/1)).

## Usage

```bash
greens                    # sync (runs setup on first use)
greens sync               # same as above
greens init               # run setup wizard (alias for --setup)
greens --status           # show config and sync status
greens --setup            # reconfigure
greens --resync           # wipe and re-sync from scratch
greens --privacy-migrate  # rewrite mirror history (upgrade from <= 1.8.1)
greens --reset            # remove everything
```

## Example output

On a verified-private mirror, the dashboard README shows where your activity came from (only people with access to your private mirror can see this):

```
Total Commits: 888 | Active Days: 158 | Repos Tracked: 11

backend-api     325  ███████░░░░░░░░░░░░░  36%
auth-service    270  ██████░░░░░░░░░░░░░░  30%
data-pipeline   246  █████░░░░░░░░░░░░░░░  27%
```

On a public (or unverifiable) mirror, this table is never written — the mirror stays empty commits only.

## The privacy rules (v1.8.2)

- Mirrors are created **private by default**; making one public requires typing `PUBLIC` in the wizard.
- The dashboard README (work repo names) is written **only while the mirror is positively verified private** via the GitHub CLI. One `gh` check per sync.
- If a mirror carrying dashboard history is public — or its visibility can't be verified (`gh` missing/logged out, non-GitHub remote) — `greens sync` refuses with exit code 3 and tells you how to fix it. There is no bypass. Make it private (and `gh auth login`), or scrub the history.
- The dashboard's status commits are authored as `greens-status <status@greens.local>`, a neutral non-account identity, so they never paint a contribution square.

## Scrubbing history: `--privacy-migrate`

Optional tooling, useful when your mirror was ever public with the dashboard in it (any greens version up to 1.8.1 wrote the dashboard unconditionally), or when you just want a mirror with nothing but empty commits.

```bash
greens --privacy-migrate
```

This one-shot command (asks for a typed `YES`):

- requires the GitHub mirror to be **private first** — it verifies visibility via `gh` and fails closed if it can't (make the repo private, then re-run)
- verifies every reachable commit in the mirror contains only greens-generated content; any user file, handwritten README, or unrecognized ref aborts the whole thing with nothing changed
- writes a private local backup bundle of the old history under `~/.contrib-mirror/backups/` (0600; it contains the old sensitive history — never upload it)
- rebuilds the history with empty-tree commits, preserving each commit's exact author **and** committer timestamps (epoch + timezone offset), so your contribution graph doesn't change
- drops greens' own synthetic init / "Update sync status" commits (identified structurally, not just by message)
- re-authors every commit as `greens <your personal email>` and redacts previously copied messages to `sync` (`--keep-messages` keeps raw commit subjects, needs a second typed `KEEP MESSAGES` ack; legacy PR/review/issue titles become generic labels either way)
- updates the default branch and deletes every stray remote ref (old branches, tags, notes) in one atomic, lease-protected force-push, then re-checks the remote before declaring success
- sets `COPY_MESSAGES=0` and never pushes any backup ref

After a scrub, the normal rule still applies going forward: if the mirror is verified private, the next sync writes a fresh dashboard; if not, it never does.

Honest limits: the old README, identities, and messages are **removed from the rewritten remote history and fresh clones** — not erased everywhere. Existing clones, forks, old-SHA URLs, caches, screenshots, and your local backup bundle still hold the old content.

## Tracks more than commits

| Activity | Tracked? |
|:---------|:--------:|
| Commits | Yes (always) |
| PRs opened | Yes (with `gh` CLI) |
| Issues opened | Yes (with `gh` CLI) |
| PR reviews | Opt-in only (GitHub exposes PR `updatedAt`, not review time — timestamps are unstable, so it's off by default) |

Set `GITHUB_USERNAME` and authenticate `gh` CLI to enable API features.

<details>
<summary>How it works under the hood</summary>

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│   Your Work Repos   │     │    Safe Cache       │     │   Public Mirror     │
│   (never touched)   │     │   (bare clones)     │     │   (empty commits)   │
├─────────────────────┤     ├─────────────────────┤     ├─────────────────────┤
│  backend-api/       │────▶│  .cache/backend.git │     │                     │
│  auth-service/      │────▶│  .cache/auth.git    │────▶│  commit: 2024-01-15 │
│  data-pipeline/     │────▶│  .cache/data.git    │     │  commit: 2024-01-16 │
└─────────────────────┘     └─────────────────────┘     │  commit: 2024-01-17 │
                                                        └─────────────────────┘
                                      +
                            ┌─────────────────────┐
                            │   GitHub API        │
                            │   (optional)        │
                            ├─────────────────────┤
                            │  PRs opened         │
                            │  Reviews submitted  │────▶  More timestamps
                            │  Issues created     │
                            └─────────────────────┘
```

</details>

<details>
<summary>Configuration reference</summary>

| Variable | Required | Default | Description |
|:---------|:--------:|:--------|:------------|
| `WORK_DIR` | Yes | `$HOME/work` | Directory containing your work repos |
| `MIRROR_DIR` | Yes | `~/.contrib-mirror/mirror` | Your public mirror repo (local clone) |
| `EMAILS` | Yes | - | Comma-separated git emails to match (exact match) |
| `REMOTE_PREFIX` | Yes | - | Only sync repos with origins starting with this |
| `MIRROR_EMAIL` | Yes | - | Personal GitHub email for mirror commits (sync exits with code 2 if unset) |
| `MIRROR_NAME` | No | `greens` | Author name for mirror commits (keep it generic) |
| `SINCE` | No | `2024-01-01` | Only sync activity after this date |
| `GITHUB_USERNAME` | No | - | Work GitHub username (enables API features) |
| `GITHUB_TOKEN` | No | - | Work account PAT (alternative to multi-account gh CLI) |
| `GITHUB_ORG` | No | (auto) | GitHub org name (auto-detected from REMOTE_PREFIX) |
| `ACTIVITY_TYPES` | No | `commits,prs,issues` | What to track (`reviews` available but opt-in) |
| `COPY_MESSAGES` | No | `0` | Set to `1` to copy raw git commit subjects (PR/issue/review items always get generic labels) |
| `COPY_MESSAGES_ACK` | No | `0` | Written by setup when you type the `COPY_MESSAGES` confirmation; sync refuses `COPY_MESSAGES=1` without it |
| `FORCE` | No | `0` | Set to `1` to bypass daily limit (does not bypass the privacy gate) |

</details>

<details>
<summary>Auth methods for multi-account setups</summary>

If your work GitHub account differs from your personal one:

| Method | Best for | Setup |
|:-------|:---------|:------|
| **Personal Access Token** | HTTPS users, simplest | Create PAT with `repo` scope, set `GITHUB_TOKEN` |
| **Multi-account gh CLI** | SSH users with multiple accounts | `gh auth login` both accounts, set `GITHUB_USERNAME` |
| **Single account** | Default `gh` account has org access | Just set `GITHUB_USERNAME` |

Works with both SSH and HTTPS repo access.

</details>

## FAQ

<details>
<summary>Is any code exposed?</summary>

No source code, ever. What IS in the mirror, honestly:

- Empty commits carrying your work **timestamps**. Whoever can see the mirror can see your work cadence (timezone, late nights, weekends, gaps). That's why mirrors are private by default; your squares still count via GitHub's "Include private contributions" toggle.
- On a **verified-private** mirror only: a dashboard README listing your work repo **names** with per-repo counts — visible solely to people with access to that private repo. On a public or unverifiable mirror the repo-names table is never written, and syncing on top of existing dashboard history is refused outright.
- `COPY_MESSAGES=1` (opt-in, typed confirmation) copies raw git commit subjects. Merge subjects commonly contain org and branch names. PR/review/issue activity always gets a generic label ("PR activity"), never the title.

If your mirror was ever public while it had the dashboard (all versions up to 1.8.1 wrote it unconditionally): `greens --privacy-migrate` scrubs it from the rewritten remote history and fresh clones.

</details>

<details>
<summary>Will this affect my private repos?</summary>

No. The script creates bare caches and never modifies your working directories.

</details>

<details>
<summary>Does it check all branches or just main?</summary>

All branches. Scans across every branch using `git log --all`. Commits aren't double-counted after merge. For squash merges, old branch commits are pruned once the remote branch is deleted.

</details>

<details>
<summary>Can the mirror repo be private?</summary>

It's private by default (since v1.8.2). Enable "Include private contributions on my profile" in [GitHub Settings > Profile](https://github.com/settings/profile) so the green squares show to visitors. A public mirror is possible but the setup wizard makes you type `PUBLIC` to confirm, because even empty commits expose your exact work timing to anyone.

</details>

<details>
<summary>Can I backfill old contributions?</summary>

Yes. Set `SINCE` to an earlier date and run `FORCE=1 greens`.

</details>

<details>
<summary>Troubleshooting</summary>

| Problem | Solution |
|:--------|:---------|
| "No matching repos found" | Check `WORK_DIR` and `REMOTE_PREFIX` match your repos |
| "clone failed" | Check SSH access: `ssh -T git@github.com` |
| "gh CLI not authenticated" | Run `gh auth login` |
| Empty contribution graph | Wait 24h for GitHub to update, or check mirror repo has commits |
| Wrong timestamps | Check `EMAILS` matches your git config |
| Mirror has wrong commits | Run `greens --resync` to wipe and re-sync |
| "not verified PRIVATE" refusal (exit 3) | Make the mirror private + `gh auth login`, or scrub with `greens --privacy-migrate` |
| Dashboard README missing | The mirror isn't verified private — check `gh auth status` and the repo's visibility |
| "MIRROR_EMAIL is not set" (exit 2) | Run `greens --setup` and set your personal GitHub email |
| "Already synced today" | Use `FORCE=1 greens` to override daily limit |

</details>

## License

MIT
