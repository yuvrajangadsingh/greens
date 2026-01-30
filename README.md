# Private Work Contributions Mirror

Mirror commit timestamps from private work repos to your GitHub contribution graph—without exposing any code.

## The Problem

You work hard on private repos, but your GitHub profile shows empty squares. Potential employers, collaborators, and the open source community can't see your actual activity.

## The Solution

This script:
1. Scans your local work repos (without modifying them)
2. Extracts commit timestamps for your email(s)
3. Creates empty commits with matching timestamps in a public mirror repo
4. Your contribution graph now reflects your real work

**No code is exposed.** Only timestamps are mirrored.

## Example Output

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

## Quick Start

### 1. Create your mirror repo

```bash
# Create a new public repo on GitHub (e.g., "work-contributions-mirror")
# Then clone it locally:
git clone git@github.com:YOUR_USERNAME/work-contributions-mirror.git ~/mirror
cd ~/mirror
git commit --allow-empty -m "init"
git push
```

### 2. Clone this repo

```bash
git clone https://github.com/yuvrajangadsingh/private-work-contributions-mirror.git
cd private-work-contributions-mirror
chmod +x sync.sh
```

### 3. Configure

Edit the variables at the top of `sync.sh`, or set environment variables:

```bash
export WORK_DIR="$HOME/work"                           # Where your work repos live
export MIRROR_DIR="$HOME/mirror"                       # Your public mirror repo
export EMAILS="work@company.com,personal@gmail.com"    # Your git emails
export REMOTE_PREFIX="git@github.com:your-company/"    # Only sync repos with this origin prefix
export SINCE="2024-01-01 00:00:00"                     # Only sync commits after this date
```

### 4. Run

```bash
./sync.sh
```

### 5. Automate (macOS)

Copy and customize the launchd plist:

```bash
cp com.contrib-mirror.plist.template ~/Library/LaunchAgents/com.contrib-mirror.plist

# Edit the plist with your paths
nano ~/Library/LaunchAgents/com.contrib-mirror.plist

# Load it
launchctl load ~/Library/LaunchAgents/com.contrib-mirror.plist
```

For Linux, use cron:

```bash
# Run daily at midnight
0 0 * * * /path/to/sync.sh >> /path/to/logs/sync.log 2>&1
```

## How It Works

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│   Private Repos     │     │    Bare Caches      │     │    Mirror Repo      │
│                     │     │                     │     │                     │
│  repo-a/ ──────────────▶  .cache/repo-a.git    │     │  Empty commits      │
│  repo-b/ ──────────────▶  .cache/repo-b.git ───────▶ │  with matching      │
│  repo-c/ ──────────────▶  .cache/repo-c.git    │     │  timestamps         │
│                     │     │                     │     │                     │
└─────────────────────┘     └─────────────────────┘     └─────────────────────┘
     Your work                 Safe fetch zone              Public repo
   (never touched)           (no blob content)           (visible on GitHub)
```

1. **Discovery**: Finds git repos in `WORK_DIR` with origins matching `REMOTE_PREFIX`
2. **Caching**: Creates bare clones to fetch safely without touching your working repos
3. **Extraction**: Gets unique commit timestamps for your email(s)
4. **Mirroring**: Creates empty commits in the mirror repo with those timestamps
5. **Stats**: Updates README with contribution breakdown

## Features

- **Safe**: Never modifies your working repos—uses bare caches
- **Efficient**: Uses `--filter=blob:none` to skip file content
- **Idempotent**: Skips already-synced timestamps
- **Lock file**: Prevents concurrent runs
- **Daily limit**: Only runs once per day (override with `FORCE=1`)
- **Stats dashboard**: Auto-generates README with contribution breakdown

## Environment Variables

| Variable | Default | Description |
|:---------|:--------|:------------|
| `WORK_DIR` | `$HOME/work` | Directory containing your private repos |
| `CACHE_DIR` | `./cache` | Where to store bare clones |
| `MIRROR_DIR` | `./mirror` | Your public mirror repo |
| `EMAILS` | (required) | Comma-separated git emails to match |
| `REMOTE_PREFIX` | (required) | Only sync repos with this origin prefix |
| `SINCE` | `2024-01-01` | Only sync commits after this date |
| `FORCE` | `0` | Set to `1` to run even if already synced today |
| `LOG_DIR` | `./logs` | Where to write logs |

## FAQ

**Q: Is any code exposed?**
A: No. Only commit timestamps are mirrored. The mirror repo contains empty commits.

**Q: Will this affect my private repos?**
A: No. The script creates bare caches and never modifies your working directories.

**Q: What if I have commits from multiple machines?**
A: As long as you sync from a machine that can access your private repos, all timestamps will be captured.

**Q: Can I backfill old contributions?**
A: Yes. Set `SINCE` to an earlier date and run with `FORCE=1`.

## License

MIT
