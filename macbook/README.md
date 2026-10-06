# MacBook

| What | Where | Backed up by |
|---|---|---|
| Code — anything with git | `~/Projects/<name>` | [backup-repos.sh](backup-repos.sh), daily at 13:00 (launchd runs a missed time on wake): one bundle per repo into Drive `Lab/Repos/macbook/` |
| Everything else | Synology Drive, `~/Library/CloudStorage/SynologyDrive-Cloud` | the Drive client → NAS `homes/merox/Cloud` |

From the NAS both go on to the vault and Oracle like any other Drive file.

Code lives in `~/Projects`, never in Drive: Drive syncs `.git` mid-write and
uploads `node_modules`. A bundle is one finished file, which Drive handles
fine. `~/Projects` sits outside `~/Documents` because macOS (TCC) refuses a
launchd job access to `~/Documents`.

## What a bundle holds

Every ref of the repository plus `refs/backup/worktree`: a commit of the
working tree, tracked and untracked files alike, `.gitignore` respected. It is
made through a throwaway index, so the repository's own index and HEAD are
never touched. More than 50 MB untracked skips the snapshot with a warning.

A bundle is rewritten only when the refs change. A repository is skipped when
the Mac holds nothing beyond origin and origin is either in the vault's
[github-repos](../truenas/config/github-repos) or someone else's. Every folder
in `~/Projects` is expected to be a git repository; anything else is logged
and not backed up.

Restore:

```sh
git clone merox.bundle merox && cd merox
git fetch ../merox.bundle refs/backup/worktree && git checkout FETCH_HEAD -- .
```

## Install

```sh
cp macbook/dev.merox.backup-repos.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.merox.backup-repos.plist
launchctl kickstart gui/$(id -u)/dev.merox.backup-repos
tail ~/Library/Logs/backup-repos.log
```
