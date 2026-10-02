# restic_rest_server

Serves the off-site restic repository over rest-server in `--append-only`
mode, and runs retention on this host — the only one allowed to delete.

## The problem it solves

A backup client that can `forget --prune` can delete the off-site copy. Root on
that client — ransomware, a wrong command, a container that escapes — would
take the last copy with it. Until 2026-09-07 that was exactly the shape here:
the backup host pushed over SFTP with full rights.

## The shape of the fix

| | |
|---|---|
| The vault writes backups | yes, as rest-server user `vault` |
| The vault can delete them | **no — 403** |
| Retention runs on | `vps01`, over the filesystem, as `restic-retention.service` |
| Retention policy | time-based (`--keep-within-*`), never counted |

The account `restic-backup` owns the repository; rest-server and the retention
container both run as it. It has no shell and no login.

## Why time-based retention

Append-only stops deletion, not insertion. A counted policy can be turned
against itself: a compromised client writes a batch of cheap snapshots, the real
ones fall out of `--keep-daily N`, and the trusted host deletes them on the
attacker's behalf. Durations make inserted snapshots cost disk and nothing else.

`restic-retention.sh` also refuses to run when any snapshot is dated in the
future, because every `--keep-within` window is measured from the newest
snapshot rather than from now — one future-dated snapshot would otherwise drag
the window forward and strand everything real outside it.

## Users

`/srv/docker/rest-server/auth/.htpasswd`, bcrypt, one line per client — today
only `vault`. The password is generated on the client and only its hash comes
here. The file must end in a newline before a line is appended, or the new
entry merges into the previous one.

## Verified 2026-09-07

```
DELETE on a data pack   -> 403
DELETE on a lock        -> 200   (restic needs it to run at all)
GET config              -> 200
wrong password          -> 401
```
