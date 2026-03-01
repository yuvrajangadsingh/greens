# greens dev notes

Binary renamed from `contrib-mirror` to `greens` in v1.6.0.
Config dir stays `~/.contrib-mirror` for backward compat.

## Release workflow

1. Make all code + CI changes, commit, push to main
2. Tag: `git tag v1.X.0 && git push origin v1.X.0`
3. Get sha: `curl -sL https://github.com/yuvrajangadsingh/greens/archive/refs/tags/v1.X.0.tar.gz | shasum -a 256`
4. Update `homebrew-contrib-mirror/Formula/greens.rb` with new tag URL + sha256
5. Push formula: `cd homebrew-contrib-mirror && git add . && git commit && git push`

**Do NOT re-tag after pushing.** Re-tagging changes the tarball sha, which breaks the formula and causes CI failures. Tag once, get sha, update formula — done.

## Repos

- Main: `yuvrajangadsingh/greens`
- Homebrew tap: `yuvrajangadsingh/homebrew-greens`

## CI

GitHub Actions runs on every push to main and on tag pushes:
- `test-scripts` — tests --version, --help, --status, --reset, setup wizard (runs always)
- `test-brew` — tests brew tap + install + upgrade (runs only on v* tags)

## Key files

- `sync.sh` — main script, CLI entry point (`greens`), version string lives here
- `setup.sh` — interactive setup wizard
- `~/.contrib-mirror/config` — user config (created by setup)
- `~/.contrib-mirror/mirror/` — default mirror repo location
