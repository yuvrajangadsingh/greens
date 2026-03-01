# greens

Mirror commit timestamps (and optionally messages) from private work repos to your GitHub contribution graph, without exposing any code.

```
Before                              After
┌────────────────────────┐          ┌────────────────────────┐
│ ░░░░░░░░░░░░░░░░░░░░░░ │          │ ░█░██░█░░█░██░█░░█░██░ │
│ ░░░░░░░░░░░░░░░░░░░░░░ │    →     │ ░█░██░█░░█░██░█░░█░██░ │
│ ░░░░░░░░░░░░░░░░░░░░░░ │          │ ░█░██░█░░█░██░█░░█░██░ │
└────────────────────────┘          └────────────────────────┘
  Private work invisible              Real activity visible
```

---

## Install

**Homebrew (recommended):**

```bash
brew install yuvrajangadsingh/greens/greens
```

**Manual:**

```bash
git clone https://github.com/yuvrajangadsingh/greens.git
cd greens
bash setup.sh
```

Setup runs automatically on first use — just run `greens`.

## Usage

```bash
greens              # run sync (auto-runs setup on first use)
greens --setup      # reconfigure
greens --status     # show current config and sync status
greens --resync     # wipe mirror history (local + remote) and sync fresh
greens --reset      # remove config, caches, and scheduler
greens --version    # show version
greens --help       # show help
```

---

## Prerequisites

| Requirement | Why | Check |
|:------------|:----|:------|
| **Git** | Clone repos, create commits | `git --version` |
| **Bash** | Run the script | `bash --version` |
| **Access to private repos** | Fetch commits (SSH or HTTPS) | `git remote -v` in any work repo |
| **GitHub CLI** (optional) | Track PRs, reviews, issues | [cli.github.com](https://cli.github.com/) |

Works with **both SSH and HTTPS** repo access.

### Auth Methods for GitHub Activity Tracking

If your work GitHub account differs from your personal one, pick **one** method:

| Method | Best for | Setup |
|:-------|:---------|:------|
| **A. Personal Access Token** | HTTPS users, CI/CD, simplest | Create PAT with `repo` scope, set `GITHUB_TOKEN` |
| **B. Multi-account gh CLI** | SSH users with multiple accounts | `gh auth login` both accounts, set `GITHUB_USERNAME` |
| **C. Single account** | Default `gh` account has org access | Just set `GITHUB_USERNAME` |

---

## How It Works

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

1. **Discover** repos in `WORK_DIR` matching `REMOTE_PREFIX`
2. **Cache** as bare clones (no file content, just git history)
3. **Extract** commit timestamps for your email(s) — uses exact email matching, scans all branches (feature, hotfix, etc.), no double-counting after merge
4. **Fetch** PR/review/issue timestamps via GitHub API (optional)
5. **Mirror** as empty commits with matching timestamps
6. **Push** to your mirror repo

---

## Configuration Reference

| Variable | Required | Default | Description |
|:---------|:--------:|:--------|:------------|
| `WORK_DIR` | Yes | `$HOME/work` | Directory containing your work repos |
| `MIRROR_DIR` | Yes | `~/.contrib-mirror/mirror` | Your public mirror repo (local clone) |
| `EMAILS` | Yes | - | Comma-separated git emails to match (exact match) |
| `REMOTE_PREFIX` | Yes | - | Only sync repos with origins starting with this |
| `MIRROR_EMAIL` | Yes | - | Personal GitHub email for mirror commits (must match a verified email on your GitHub account) |
| `SINCE` | No | `2024-01-01` | Only sync activity after this date |
| `GITHUB_USERNAME` | No | - | Your work GitHub username (enables API features) |
| `GITHUB_TOKEN` | No | - | Work account PAT (alternative to multi-account gh CLI) |
| `GITHUB_ORG` | No | (auto) | GitHub org name (auto-detected from REMOTE_PREFIX) |
| `ACTIVITY_TYPES` | No | `commits,prs,reviews,issues` | What to track |
| `COPY_MESSAGES` | No | `0` | Set to `1` to copy commit messages (not just timestamps) |
| `FORCE` | No | `0` | Set to `1` to bypass daily limit |
| `LOG_DIR` | No | `./logs` | Where to write logs |
| `CACHE_DIR` | No | `./.cache` | Where to store bare clones |

---

## GitHub Activity Tracking

GitHub's contribution graph counts more than commits:

| Activity | Counts? | Tracked by this script? |
|:---------|:-------:|:-----------------------:|
| Commits | Yes | Yes (always) |
| PRs opened | Yes | Yes (with `gh` CLI) |
| PR reviews | Yes | Yes (with `gh` CLI) |
| Issues opened | Yes | Yes (with `gh` CLI) |
| Comments | No | - |

**To enable:** Set `GITHUB_USERNAME` and authenticate `gh` CLI with access to your work org.

```bash
# Check if gh can access your org
gh search prs --author=YOUR_USERNAME --owner=YOUR_ORG --limit=1
```

---

## FAQ

**Q: Is any code exposed?**

No. By default, only timestamps are mirrored. The mirror repo contains empty commits with no content. If you enable `COPY_MESSAGES=1`, commit messages will be visible in the public mirror—no code is ever exposed.

**Q: Will this affect my private repos?**

No. The script creates bare caches and never modifies your working directories.

**Q: What if I have multiple GitHub accounts (work/personal)?**

Use SSH config with different hosts for repo access. For GitHub API (PRs/reviews), either set `GITHUB_TOKEN` with a work account PAT, or login with both accounts via `gh auth login` and set `GITHUB_USERNAME`. See **Auth Methods** above.

**Q: Does it check all branches or just main?**

All branches. The script scans commits across every branch (feature, hotfix, release, etc.) using `git log --all`. Commits aren't double-counted after merge—git deduplicates by commit hash. For squash merges, old branch commits are pruned once the remote branch is deleted.

**Q: Can the mirror repo be private?**

Yes. Enable "Include private contributions on my profile" in [GitHub Settings > Profile](https://github.com/settings/profile) so the green squares show to visitors.

**Q: Can I backfill old contributions?**

Yes. Set `SINCE` to an earlier date and run with `FORCE=1 greens`.

**Q: The script says "Already synced today"**

It only runs once per day by default. Use `FORCE=1 greens` to override.

**Q: My mirror has wrong commits or someone else's activity**

Run `greens --resync`. It wipes the mirror (local + remote) and does a clean sync.

**Q: GitHub API features not working?**

Check:
1. `gh auth status` - are you logged in?
2. `gh search prs --owner=YOUR_ORG --limit=1` - can you access the org?
3. Is `GITHUB_USERNAME` set correctly?
4. If using a PAT, is `GITHUB_TOKEN` set and does it have `repo` scope?

---

## Example Output

After running, your mirror repo's README shows:

| Metric | Value |
|:-------|------:|
| Total Commits | **888** |
| Active Days | **158** |
| Repos Tracked | **11** |

| Repository | Commits | Distribution |
|:-----------|--------:|:-------------|
| `backend-api` | 325 | `███████░░░░░░░░░░░░░` 36% |
| `auth-service` | 270 | `██████░░░░░░░░░░░░░░` 30% |
| `data-pipeline` | 246 | `█████░░░░░░░░░░░░░░░` 27% |

---

## Troubleshooting

| Problem | Solution |
|:--------|:---------|
| "No matching repos found" | Check `WORK_DIR` and `REMOTE_PREFIX` match your repos |
| "clone failed" | Check SSH access: `ssh -T git@github.com` |
| "gh CLI not authenticated" | Run `gh auth login` |
| Empty contribution graph | Wait 24h for GitHub to update, or check mirror repo has commits |
| Wrong timestamps | Check `EMAILS` matches your git config |
| Mirror has wrong commits | Run `greens --resync` to wipe and re-sync |

---

## License

MIT
