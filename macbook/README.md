# MacBook

The Mac is a backup producer like any other: it writes what only it holds to
the NAS's `backups/macbook/`, and the vault and Oracle take it from there.

| What | How | Where |
|---|---|---|
| Git repositories in `~/Projects` | [backup-repos.sh](backup-repos.sh), daily at 13:00 (launchd runs a missed time on wake) | `backups/macbook/repos/<name>.bundle` |
| Documents | Synology Drive client, `~/Library/CloudStorage/SynologyDrive-Cloud` | `homes/merox/Cloud` |
| Everything else (dotfiles, keys, apps) | Time Machine — not set up yet | — |

Code lives in `~/Projects`, never in a synced folder: Drive's sync of `.git`
and `node_modules` produces conflicts and corrupt repositories. Projects sit
outside `~/Documents` because macOS (TCC) refuses a launchd job access to it.

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

## Setup

On the NAS, once (Control Panel → User & Group):

1. User `macbook`, member of `users` only. Applications: SFTP and rsync.
   Shared folder `backups` read/write, everything else no access. Quota on
   `volume1`: 1 GB.
2. Create `backups/macbook/repos/`.
3. Install the key, as `admin` over SSH (DSM creates homes `777`, which sshd
   refuses):

   ```sh
   sudo mkdir -p /var/services/homes/macbook/.ssh
   echo '<contents of ~/.ssh/nas_macbook.pub>' | sudo tee /var/services/homes/macbook/.ssh/authorized_keys
   sudo chown -R macbook:users /var/services/homes/macbook
   sudo chmod 755 /var/services/homes/macbook
   sudo chmod 700 /var/services/homes/macbook/.ssh
   sudo chmod 600 /var/services/homes/macbook/.ssh/authorized_keys
   ```

On the Mac:

```sh
ssh-keygen -t ed25519 -N '' -C macbook-backup -f ~/.ssh/nas_macbook
ssh -i ~/.ssh/nas_macbook macbook@10.57.57.201 true    # accept the host key
cp macbook/dev.merox.backup-repos.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.merox.backup-repos.plist
launchctl kickstart gui/$(id -u)/dev.merox.backup-repos
tail ~/Library/Logs/backup-repos.log
```

The key carries no `from=` restriction: the Mac reaches the NAS from the LAN
and over Tailscale, and the account can write only its quota into `backups`.

macOS ships openrsync, which has no `--chmod`; the script pushes with
`--no-perms --no-owner --no-group` so DSM's ACLs stay in charge.
