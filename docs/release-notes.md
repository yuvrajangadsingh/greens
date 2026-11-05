# Unreleased

## Homebrew upgrade action

After upgrading, run `greens --setup` once to recreate your scheduled job.
Earlier Homebrew releases installed the sync executable outside the directory
used by setup, and existing jobs may point at a versioned Cellar path that is
removed during an upgrade.

New Homebrew installations package the complete runtime in `libexec`. Setup
schedules it through `<Homebrew prefix>/opt/greens/libexec/sync.sh`, so scheduled
jobs follow future upgrades. Rerunning setup also removes legacy untagged cron
jobs pointing at previous versions and replaces the legacy launchd agent.

## Multiple GitHub accounts

Setup and sync use command-local credentials for the saved source and destination
accounts. They preserve the active GitHub CLI account, support simultaneous
configurations, and can use a valid saved account even if the active account has
expired. Existing SSH destination aliases remain usable during setup migration.

Saved account names are matched without regard to case. Matching explicit PATs
retain priority over saved CLI tokens, and credentials embedded in existing HTTPS
mirror URLs continue to work without a separate personal CLI login. Git helpers
are scoped to the clone host; plain HTTP keeps its configured helpers.

## Sync reliability and development-build compatibility

The Perl timeout fallback now preserves successful exit codes, closes output
pipes immediately, and terminates the command's process group on a deadline.
Each configuration has a separate bare-repository cache, so simultaneous syncs
sharing a cache directory cannot race while initializing or fetching a repo.
Existing activity state is retained; bare repositories are fetched again once.

GitHub activity markers from earlier builds with mixed-case owners/repositories
are recognized from retained checkout URLs and the configuration's activity
cache. Keep that cache during the upgrade if URLs have also changed casing.
An opaque old hash cannot recover spelling when both sources of that spelling
have been removed; this affects development builds predating normalization,
not released v1.8.2 configurations.

## Generic Git endpoints and scan depth

Generic Git repository identities now retain explicit transport ports instead
of merging different servers on the same host/path. Earlier development builds
used a portless identity, so endpoint activities from those builds may be emitted
again after this correction; released v1.8.2 configurations are unaffected.

Explicit `--in-root` setup removes saved groups that still have checkouts in
excluded nested folders. It retains genuinely unavailable groups, and a fresh
sync no longer fails because of a local group excluded by the requested depth.

## Scheduled dependencies and cache reuse

Launchd saves the setup PATH with XML escaping, matching cron and systemd.
Destination Git commands isolate personal credentials even when a mirror URL
contains only a username and an ambient work token is exported.

Upgrades can seed each configuration's private bare cache from a self-contained
old cache using a local copy with independent objects/refs and fresh transport
configuration. This avoids repeating a full network clone for large histories.
Generic SSH repository identities also distinguish login homes and login casing.
