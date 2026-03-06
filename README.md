# greens

Your work is real. Your contribution graph should show it.

If you commit to private/org repos all day but your GitHub profile looks empty, greens fixes that. It mirrors commit timestamps (and optionally PRs, reviews, issues) to a public repo without exposing any code.

<p align="center">
  <img src="assets/demo.svg" alt="greens demo" width="600">
</p>

## Install

```bash
brew install yuvrajangadsingh/greens/greens
```

Then just run `greens`. Setup wizard runs on first use.

<details>
<summary>Manual install (without Homebrew)</summary>

```bash
git clone https://github.com/yuvrajangadsingh/greens.git
cd greens
bash setup.sh
```

</details>

## What it does

1. Scans your work repos (never modifies them)
2. Extracts commit timestamps for your email(s) across all branches
3. Optionally fetches PR/review/issue timestamps via GitHub API
4. Creates empty commits with matching timestamps in a mirror repo
5. Pushes to your public mirror

No code is exposed. The mirror contains empty commits with only timestamps.

**Works with any git remote.** Your source repos can be on GitHub, GitLab, Bitbucket, or self-hosted. greens scans the local clone, not the remote. The mirror destination is GitHub (GitLab/Bitbucket mirror support is [planned](https://github.com/yuvrajangadsingh/greens/issues/1)).

## Usage

```bash
greens              # sync (runs setup on first use)
greens sync         # same as above
greens init         # run setup wizard (alias for --setup)
greens --status     # show config and sync status
greens --setup      # reconfigure
greens --resync     # wipe and re-sync from scratch
greens --reset      # remove everything
```

## Example output

After syncing, your mirror repo shows:

```
Total Commits: 888 | Active Days: 158 | Repos Tracked: 11

backend-api     325  ███████░░░░░░░░░░░░░  36%
auth-service    270  ██████░░░░░░░░░░░░░░  30%
data-pipeline   246  █████░░░░░░░░░░░░░░░  27%
```

## Tracks more than commits

| Activity | Tracked? |
|:---------|:--------:|
| Commits | Yes (always) |
| PRs opened | Yes (with `gh` CLI) |
| PR reviews | Yes (with `gh` CLI) |
| Issues opened | Yes (with `gh` CLI) |

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
| `MIRROR_EMAIL` | Yes | - | Personal GitHub email for mirror commits |
| `SINCE` | No | `2024-01-01` | Only sync activity after this date |
| `GITHUB_USERNAME` | No | - | Work GitHub username (enables API features) |
| `GITHUB_TOKEN` | No | - | Work account PAT (alternative to multi-account gh CLI) |
| `GITHUB_ORG` | No | (auto) | GitHub org name (auto-detected from REMOTE_PREFIX) |
| `ACTIVITY_TYPES` | No | `commits,prs,reviews,issues` | What to track |
| `COPY_MESSAGES` | No | `0` | Set to `1` to copy commit messages (not just timestamps) |
| `FORCE` | No | `0` | Set to `1` to bypass daily limit |

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

No. Only timestamps are mirrored. The mirror repo contains empty commits with no content. If you enable `COPY_MESSAGES=1`, commit messages will be visible but no code is ever exposed.

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

Yes. Enable "Include private contributions on my profile" in [GitHub Settings > Profile](https://github.com/settings/profile) so the green squares show to visitors.

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
| "Already synced today" | Use `FORCE=1 greens` to override daily limit |

</details>

## License

MIT
