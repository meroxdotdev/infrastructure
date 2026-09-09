# restic_rest_server

Serves the existing off-site restic repository over rest-server in
`--append-only` mode, and moves retention off the machine that writes backups.

## The problem it solves

`restic-push-oracle.sh` on `pve-2` ran `backup`, then `forget --prune`, then
`check`, over an SFTP chroot whose key lives on `pve-2`. Root on that host —
ransomware, a wrong command, a container that escapes — could therefore delete
the off-site copy. The weekly Synology leg is a push from the same host, and the
third copy is local to it. Three copies, every one of them destroyable from the
one machine most likely to be the problem.

## The shape of the fix

| | Before | After |
|---|---|---|
| `pve-2` writes backups | yes | yes |
| `pve-2` can delete them | **yes** | **no — 403** |
| Retention runs on | `pve-2` | `vps01`, over the filesystem |
| Retention policy | counted (`--keep-daily 7`) | time-based (`--keep-within-*`) |

Nothing was copied to stand this up. rest-server serves the same 67 GiB
directory the SFTP chroot served; only the door changed.

## Why time-based retention

Append-only stops deletion, not insertion. A counted policy can be turned
against itself: a compromised client writes a batch of cheap snapshots, the real
ones fall out of `--keep-daily N`, and the trusted host deletes them on the
attacker's behalf. Durations make inserted snapshots cost disk and nothing else.

`restic-retention.sh` also refuses to run when any snapshot is dated in the
future, because every `--keep-within` window is measured from the newest
snapshot rather than from now — one future-dated snapshot would otherwise drag
the window forward and strand everything real outside it.

## Verified 2026-09-07

```
DELETE on a data pack   -> 403      restic forget from pve-2 -> 403, 0/8 deleted
DELETE on a lock        -> 200      SFTP from pve-2          -> Permission denied
GET config              -> 200      backup + check from pve-2 -> exit 0
wrong password          -> 401      repo after all of it      -> 13 snapshots, no errors
```

## Rollback

`/srv/restic-repo/.ssh/authorized_keys.disabled-2026-09-07` holds the SFTP key
that was in use. Restoring it re-opens the old path; the repository is the same
on both.

## Not covered here

The weekly Synology copy was flipped to a pull on 2026-09-07. `pve-2` now holds
no credential for either target: it can add here and cannot delete, and the NAS
reaches in over `rrsync -ro` rather than being pushed to.
