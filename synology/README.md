# Synology DS — `storage`, `10.57.57.201`

DSM 7.3. Holds the second copy of `pve-2`'s backup set under
`/volume1/NetBackup`, 276 GB of 1.8 TB.

## It pulls; it is not pushed to

Until 2026-09-07 `weekly-push-to-synology.sh` ran on `pve-2`, held a key into
this NAS, and ran `rsync --delete` against it. The NAS copy was therefore
destroyable from `pve-2` — the host whose compromise is the entire reason the
copy exists. The off-site restic repository had the same shape, and the third
copy is local to `pve-2`. Three copies, all reachable from one machine.

Now the trust runs one way only:

| | Before | After |
|---|---|---|
| `pve-2` → NAS | key with write + `--delete` | **no credential at all** |
| NAS → `pve-2` | — | two keys, each `rrsync -ro` over one directory |
| Retention | run by `pve-2` | run here, 21 days |

Two keys rather than one rooted at `/media`, so neither can reach
`/media/library` (1.1 TB) or `/media/isos`:

```
restrict,command="rrsync -ro /media/backups",from="10.57.57.201"  nas-pull-backups@storage
restrict,command="rrsync -ro /media/photos",from="10.57.57.201"   nas-pull-photos@storage
```

## Verified 2026-09-07

```
pve-2 → NAS over the old key      Permission denied (publickey,password)
NAS writing back to pve-2         "sending to read-only server is not allowed"
NAS running any non-rsync command "SSH_ORIGINAL_COMMAND does not run rsync"
photos key listing /media/backups only ever sees /media/photos
full pull                         9 categories, 0 failures, 44s
```

44 seconds because `--link-dest` hardlinks everything unchanged against the
previous dated copy; only genuinely new files cross the wire.

## Scheduling

`pull-from-pve2.sh` is not in cron. DSM owns scheduling through Control Panel →
Task Scheduler, and a hand-edited `/etc/crontab` is liable to be rewritten by
DSM. Create a weekly user-defined script task running
`/volume1/NetBackup/pull-from-pve2.sh` as root, inside the NAS's wake window.

Until that task exists this runs only when started by hand, and the
`pve-push-synology` healthcheck (period 1 week, grace 1 day) will go red — which
is the intended behaviour, not a bug.

## Stale keys, not touched

`~/.ssh/authorized_keys` still trusts `root@pve`, two `root@solex` entries and
`merox@macbook`. `root@pve` is **not** `pve-2`'s current key — fingerprints were
compared on 2026-09-07 and none of `pve-2`'s keys match it, so it is an orphan
from an older install. Nobody knows who holds these; they were left in place
rather than removed blind.

Previous file kept at `~/.ssh/authorized_keys.pre-pull-2026-09-07`.
