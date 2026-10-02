# Synology DS — `storage`, `10.57.57.201`

DSM 7.3. Holds the second copy of `pve-2`'s backup set under
`/volume1/NetBackup`.

## Layout, since 2026-09-29

The NAS is becoming primary storage — see
[docs/plan-nas-hot-r730-cold.md](../docs/plan-nas-hot-r730-cold.md). It is on
24/7: no power schedule, no drive hibernation, *Restart automatically when
power supply issue is fixed* on, and it is a NUT client of pve-1 (DSM → UPS →
Synology UPS server `10.57.57.254`). DSM notifies when Volume 1 has less than
20% free.

The library rotates itself: qBittorrent removes a torrent and its files after
3 days of seeding (the library keeps its hardlink), and Radarr/Sonarr import
by hardlink, never by copy.

| Share | Holds | Recycle bin | Checksum |
|---|---|---|---|
| `media` | `Movies/`, `Shows/`, `Downloads/` — one share, or ARR hardlink imports break. **Quota 1.2 TB**, so the library can never eat the space backups need | off | on |
| `backups` | the landing: one folder per producer, latest version only | off | on |
| `homes` | Synology Drive and Synology Photos (personal spaces). The VirtualBox images moved to the vault on 2026-10-02 (`files/Personal/VMs`, vault-only) | default | — |
| `NetBackup` | the old weekly pull from pve-2; deleted in phase 7 | — | — |

### NFS

NFSv4.1. `media` and `backups` each have one rule per Kubernetes node
(`10.57.57.80`, `.82`, `.83`), never the subnet:

| Setting | Value | Why |
|---|---|---|
| Privilege | Read/Write | |
| Squash | **Map all users to admin** | pods write as UID 1000, which is no DSM user, so DSM's ACL refused every write under *No mapping*. Mapping everyone to `admin` is the standard way to give Kubernetes clients one owner the ACLs recognise |
| Security | sys | |
| Asynchronous | on for `media`, **off** for `backups` | a backup must be on disk when the writer is told it is |
| Mounted subfolders | on | the `crossmnt` equivalent |

Verified 2026-09-29 from all three nodes as UID 1000: write, read, and a
hardlink (link count 2) on both shares.

### Users

One user per job, none in `administrators` except `admin`:

| User | Can | Quota |
|---|---|---|
| `admin` | administration | — |
| `merox`, `vicky` | Synology Drive | — |
| `pfsense` | SFTP only, `backups` read/write | 1 GB |
| `vps` | SFTP + rsync, `backups` read/write | 10 GB |

`pfsense` and `vps` authenticate with their existing backup keys, restricted to
`from="10.57.57.1"` — pfSense itself, and the VPS arriving through pfSense's
NAT. Installing a key for a non-admin user needs root once: sshd refuses a key
file the user does not own and a home that is group-writable, and DSM creates
homes `777`.

Traps found while setting this up:

- rsync over SSH needs the full path, `vps@nas:/volume1/backups/…`;
  `/backups/…` is read as an rsync module and fails with no message.
- `rsync -a` replaces DSM's ACL with Unix modes; push with
  `--no-perms --no-owner --no-group --chmod=D755,F644`.
- Legacy `scp -O` does not work for a non-admin user; plain `scp` (SFTP) does.

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

## `documents/` — removed 2026-09-29

It was the last copy of the old `synology-home` tree, not a mirror of anything
on `pve-2`. Every file was compared by SHA-1 against Immich's files on disk,
Nextcloud's datadir and the git history of the blog repositories: 99 % existed
elsewhere. The 30 files that did not (personal PDFs, merox.dev notes) were
copied into Nextcloud under `Documente/` and verified by hash; the rest was
deleted.

Immich's database checksum cannot be used for this comparison: for assets in an
external library it hashes the path, not the content. Hash the files on disk.

`vm-backups/` is orphaned the same way, and is safe to delete: it holds images
of `home-assistant` and `ollama`, both VMs deleted on 2026-09-09.

## Stale keys, not touched

`~/.ssh/authorized_keys` still trusts `root@pve`, two `root@solex` entries and
`merox@macbook`. `root@pve` is **not** `pve-2`'s current key — fingerprints were
compared on 2026-09-07 and none of `pve-2`'s keys match it, so it is an orphan
from an older install. Nobody knows who holds these; they were left in place
rather than removed blind.

Previous file kept at `~/.ssh/authorized_keys.pre-pull-2026-09-07`.
