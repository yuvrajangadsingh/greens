# Private Work Contributions Mirror

Mirror commit timestamps from private work repos to your GitHub contribution graph—without exposing any code.

## The Problem

You work hard on private repos, but your GitHub profile shows empty squares. Recruiters, collaborators, and the open source community can't see your actual activity.

## The Solution

This script mirrors your work activity to a public repo. **No code is exposed**—only timestamps.

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

## Prerequisites

### Required

| Requirement | Why | Check |
|:------------|:----|:------|
| **Git** | Clone repos, create commits | `git --version` |
| **Bash** | Run the script | `bash --version` |
| **SSH access** to private repos | Fetch commits | `ssh -T git@github.com` |

### Optional (for PR/review/issue tracking)

| Requirement | Why | Install |
|:------------|:----|:--------|
| **GitHub CLI** | Fetch PRs, reviews, issues | [cli.github.com](https://cli.github.com/) |

```bash
# Install gh (macOS)
brew install gh

# Authenticate
gh auth login
```

---

## Setup (5 minutes)

### Step 1: Create a mirror repo on GitHub

1. Go to [github.com/new](https://github.com/new)
2. Name it something like `work-contributions-mirror`
3. Make it **public** (so it shows on your profile)
4. Don't initialize with README

### Step 2: Clone the mirror repo locally

```bash
git clone git@github.com:YOUR_USERNAME/work-contributions-mirror.git ~/mirror
cd ~/mirror
git commit --allow-empty -m "init"
git push
```

### Step 3: Clone this script

```bash
git clone https://github.com/yuvrajangadsingh/private-work-contributions-mirror.git
cd private-work-contributions-mirror
chmod +x sync.sh
```

### Step 4: Configure

Create a config file or export environment variables:

```bash
# Required
export WORK_DIR="$HOME/work"                          # Directory with your work repos
export MIRROR_DIR="$HOME/mirror"                      # Mirror repo from Step 2
export EMAILS="you@company.com,personal@gmail.com"    # Your git email(s)
export REMOTE_PREFIX="git@github.com:your-company/"   # Only sync repos matching this

# Optional
export SINCE="2024-01-01 00:00:00"                    # Start date for sync
export GITHUB_USERNAME="your-github-username"         # For PR/review/issue tracking
```

**Finding your values:**

```bash
# Find your git email
git config user.email

# Find your remote prefix (run in any work repo)
git remote -v | grep origin
# Output: git@github.com:acme-corp/repo.git
# Your REMOTE_PREFIX: git@github.com:acme-corp/
```

### Step 5: Run

```bash
./sync.sh
```

First run will take longer (cloning repos). Subsequent runs are fast.

---

## Automate (run daily)

### macOS (launchd)

```bash
cp com.contrib-mirror.plist.template ~/Library/LaunchAgents/com.contrib-mirror.plist

# Edit paths in the plist
nano ~/Library/LaunchAgents/com.contrib-mirror.plist

# Load it
launchctl load ~/Library/LaunchAgents/com.contrib-mirror.plist
```

### Linux (cron)

```bash
crontab -e

# Add this line (runs daily at midnight)
0 0 * * * cd /path/to/private-work-contributions-mirror && ./sync.sh >> logs/sync.log 2>&1
```

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
3. **Extract** commit timestamps for your email(s)
4. **Fetch** PR/review/issue timestamps via GitHub API (optional)
5. **Mirror** as empty commits with matching timestamps
6. **Push** to your public mirror repo

---

## Configuration Reference

| Variable | Required | Default | Description |
|:---------|:--------:|:--------|:------------|
| `WORK_DIR` | Yes | `$HOME/work` | Directory containing your work repos |
| `MIRROR_DIR` | Yes | `./mirror` | Your public mirror repo (local clone) |
| `EMAILS` | Yes | - | Comma-separated git emails to match |
| `REMOTE_PREFIX` | Yes | - | Only sync repos with origins starting with this |
| `SINCE` | No | `2024-01-01` | Only sync activity after this date |
| `GITHUB_USERNAME` | No | - | Your GitHub username (enables API features) |
| `GITHUB_ORG` | No | (auto) | GitHub org name (auto-detected from REMOTE_PREFIX) |
| `ACTIVITY_TYPES` | No | `commits,prs,reviews,issues` | What to track |
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
A: No. Only timestamps are mirrored. The mirror repo contains empty commits with no content.

**Q: Will this affect my private repos?**
A: No. The script creates bare caches and never modifies your working directories.

**Q: What if I have multiple GitHub accounts (work/personal)?**
A: Use SSH config with different hosts. Set `REMOTE_PREFIX` to match your work repos only.

**Q: Can I backfill old contributions?**
A: Yes. Set `SINCE` to an earlier date and run with `FORCE=1`.

**Q: The script says "Already synced today"**
A: It only runs once per day by default. Use `FORCE=1 ./sync.sh` to override.

**Q: GitHub API features not working?**
A: Check:
1. `gh auth status` - are you logged in?
2. `gh search prs --owner=YOUR_ORG --limit=1` - can you access the org?
3. Is `GITHUB_USERNAME` set correctly?

---

## Example Output

After running, your mirror repo's README shows:

```
| Metric | Value |
|:-------|------:|
| Total Commits | 888 |
| Active Days | 158 |
| Repos Tracked | 11 |

| Repository | Commits | Distribution |
|:-----------|--------:|:-------------|
| `backend-api` | 325 | ███████░░░░░░░░░░░░░ 36% |
| `auth-service` | 270 | ██████░░░░░░░░░░░░░░ 30% |
| `data-pipeline` | 246 | █████░░░░░░░░░░░░░░░ 27% |
```

---

## Troubleshooting

| Problem | Solution |
|:--------|:---------|
| "No matching repos found" | Check `WORK_DIR` and `REMOTE_PREFIX` match your repos |
| "clone failed" | Check SSH access: `ssh -T git@github.com` |
| "gh CLI not authenticated" | Run `gh auth login` |
| Empty contribution graph | Wait 24h for GitHub to update, or check mirror repo has commits |
| Wrong timestamps | Check `EMAILS` matches your git config |

---

## License

MIT
