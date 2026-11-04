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
