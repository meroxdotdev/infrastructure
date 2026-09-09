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
DSM. The task exists as of 2026-09-09: a weekly user-defined script running
`bash /volume1/NetBackup/pull-from-pve2.sh` as **root** — it needs root to write
over the mixed ownership left by the old push.

The times are deliberately not in this file. They are the NAS's wake window, and
this repository is public; a window is the one thing worth knowing about a
machine that holds the only offline copy. They live in `/root/PRIVATE-NOTES.md`
on `pve-2`, next to the WoL MAC, for the same reason the weekly crontab line is
redacted there — see `proxmox/pve-2/REINSTALL.md` §9.

The order those times have to keep, which is the part worth writing down:

1. The NAS wakes on an RTC schedule. Nothing in cron does this, so it is
   invisible from the shell — `wakeonlan` with the MAC from the private notes is
   the manual equivalent.
2. `pve-2` refreshes `/media/backups` — garage metadata, etcd, ZFS snapshots,
   restic, then the nightly checks. About twenty minutes, all in its own crontab.
3. **Then** the pull runs. Earlier and it copies yesterday's set while tonight's
   is still being written.
4. The NAS powers itself off on the schedule's other half.

Step 3 must finish before step 4, and DSM's scheduled power-off does not wait
for a running task. A truncated pull is not corruption — `rsync` repairs it the
following week — but it leaves a dated directory that looks like a copy and is
not one, so leave real margin rather than the minimum that fits. The gap was 15
minutes until 2026-09-09 and is now 95.

Measured cost, so the margin can be judged: 45 s for a one-day delta, 3 min for
the same set pulled again. Both against a recent `--link-dest` base — a full
week of deltas moves more, mostly new Longhorn chunks and borg segments, which
are genuinely new files and do cross the wire.

If the task is ever lost, this runs only when started by hand, and the
`pve-push-synology` healthcheck (period 1 week, grace 1 day) goes red — which is
the intended behaviour, not a bug.

## Stale keys, not touched

`~/.ssh/authorized_keys` still trusts `root@pve`, two `root@solex` entries and
`merox@macbook`. `root@pve` is **not** `pve-2`'s current key — fingerprints were
compared on 2026-09-07 and none of `pve-2`'s keys match it, so it is an orphan
from an older install. Nobody knows who holds these; they were left in place
rather than removed blind.

Previous file kept at `~/.ssh/authorized_keys.pre-pull-2026-09-07`.
