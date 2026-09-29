# Plan — the NAS goes hot, the R730xd becomes a cold vault

**Revised 2026-09-28.** Replaces the 2026-09-15 draft, which assumed new NAS
disks and kept Nextcloud. Nothing here is started.

Three decisions changed since that draft:

- The NAS runs on the **disks it already has** (2× 2 TB). New disks are a
  trigger, not a prerequisite — see [The NAS disks](#the-nas-disks).
- **Nextcloud goes.** Synology Drive on the NAS replaces it.
- The R730xd leaves Proxmox for **TrueNAS SCALE**, is awake **~40 min a
  night** (longer once a month), and is the one place every copy converges on.

---

## The shape after

| Machine | Runs | Always on |
|---|---|---|
| `pve-1` Beelink | `kubernetes-1` (iGPU), **NUT primary** (UPS on its USB since 2026-09-29) | yes |
| `pve-3` OptiPlex | `kubernetes-3`, PDM, **Garage LXC**, **heartbeat**, **vault wake** | yes |
| mini PC (spare OptiPlex) | Proxmox + `kubernetes-2` — replaces VM 811 | yes |
| Synology DS223 | media library, Synology Drive, **backup landing**, Garage data | yes |
| R730xd | TrueNAS SCALE — **the vault** | ~40 min/night |

Three etcd votes stay in three chassis. The R730xd holds no workload, so it
can be off without anything noticing except its own healthcheck.

## The flow

```
Longhorn ──→ Garage ─┐
Immich pg_dump       │
etcd snapshot        ├─→ NAS /backups ──┐
pfSense config       │   (landing)      │  nightly, pull-only
VPS services         ┘                  ├─→ R730xd vault ──→ restic ──→ Oracle
NAS /drive  (Drive, was Nextcloud) ─────┤   ZFS snapshots      (append-only)
NAS /media  (library, 1.2 TB) ──────────┘   long retention
GitHub repos (mirror) ──────────────────────┘
```

Two rules, both carried over:

1. **Every producer writes to the NAS, whenever it likes.** Nothing aligns with
   anything. The UTC-vs-EEST window in
   [proxmox/pve-2/README.md](../proxmox/pve-2/README.md#nightly-schedule) stops
   existing, because only one machine has a window.
2. **Trust runs one way.** The vault holds read-only credentials into the NAS
   and the restic credentials to Oracle. The NAS holds nothing that reaches the
   vault. Oracle cannot be deleted from by the vault. Nothing can delete its own
   backups.

Copies after the change:

| Data | Copy 1 | Copy 2 | Copy 3 |
|---|---|---|---|
| Tier 1 (Immich, Drive files, pfSense, Authentik…) | live (Longhorn / NAS) | vault, snapshotted | Oracle |
| Longhorn tier 2 | Longhorn replicas | NAS via Garage → vault | Oracle |
| Film library (tier 3) | NAS | **vault** — first second copy ever | — |

---

## The NAS disks

Read 2026-09-28 from DSM's SMART cache (`/run/synostorage/disks/*`); `smartctl`
itself needs root.

| | sata1 | sata2 |
|---|---|---|
| Model | WD RE4 `WD2003FYYS` (enterprise, 7200 rpm, **CMR**) | same |
| Power-on | 50,443 h (5.8 y) | 51,920 h (5.9 y) |
| Reallocated / pending / uncorrectable | 0 / 0 / 0 | 0 / 0 / 0 |
| UDMA CRC errors | 0 | **35** — cable/backplane history, not media |
| Start/stop | 7,900 | 7,898 |
| Array | md2 RAID1 `[UU]`, `vg1` (SHR), 1.8 T, 358 G used | |

**Verdict:** the media surface is clean. Their risk is age and pairing — same
model, same batch (serials `WCAY016…`), same hours, so they are likely to fail
close together, which is exactly the failure RAID1 does not survive.

That risk is acceptable **only because the vault holds a copy of everything on
the NAS**, library included. Without the vault these disks should not be a
primary.

**Capacity is the tighter constraint:**

| On the NAS after migration | Size |
|---|---|
| `media/library` | 1.19 T |
| `public/library` | 34 G |
| backup landing (no `dump/`, no borg) | ~30 G |
| Drive (Nextcloud data) | ~17 G |
| `documents/` until resolved | 30 G |
| **Total** | **~1.3 T of 1.8 T — 72 %** |

Fits, with ~400 G of growth. The old `NetBackup` (358 G) must be gone before
the library copies in, or the volume hits 90 %.

**Replace the pair when either happens:** any reallocated/pending sector on
either disk, or the volume passes 80 %. Swap one disk, rebuild, swap the
other, expand — SHR does this in place, no wipe. 2× 8 TB CMR (Red Plus /
IronWolf / N300). Not SMR.

**Before anything else:** run an **extended** SMART test on both from DSM
(Storage Manager → HDD → S.M.A.R.T. Test; ~5 h each). The cache has never shown
one completing.

---

## What leaves

| Removed | Replaced by |
|---|---|
| Nextcloud VM 1000, AIO (9 containers), Collabora, its Cloudflare tunnel | Synology Drive + Office, Tailscale on DSM |
| Borg repo + its password — **the third secret** | nothing; back to two |
| Weekly vzdump, `dump/` (58 G), vzdump-age check | nothing to dump |
| Proxmox on the R730xd, `reinstall.sh`, `REINSTALL.md` | TrueNAS install + config export |
| Spin-down enforcer, `install-spindown.sh`, `spindown-setup.md` | host is off ~23 h/day; disks never spin down while it runs |
| `garage-meta-nightly-copy.sh` | Garage meta no longer on a SAS pool |
| `zfs-snapshot-backups.sh` | TrueNAS periodic snapshot task |
| `pull-from-pve2.sh`, NAS RTC wake + scheduled poweroff | NAS is always on; vault pulls |
| `restic-restore-drill.sh` as a pve-2 script | TrueNAS cron job, same logic |
| NAS `NetBackup/vm-backups` (48 G, VMs deleted 2026-09-09) | — |
| Kali VM 106 | export first if wanted |

**14 scripts and 7 cron lines on pve-2, plus 2 DSM tasks → one chain script,
`fan-control.sh`, and one wake line on pve-3.** Everything else is a built-in
TrueNAS task. Full before → after table in
[plan-truenas-vault.md](plan-truenas-vault.md#every-scheduled-job-before--after).

## What stays, and why

- **Garage.** Closed 2026-09-09: Longhorn's NFS backupstore loses backups
  quietly. It moves; it is not replaced.
- **Proxmox on every host, the mini PC included.** Decided 2026-09-28: VMs for
  testing, spare capacity if a host dies, and Terraform and the DR runbook
  assume every node is a VM. Bare-metal Talos was considered and rejected.
- **`fan-control.sh`.** More important than before — the vault now runs in the
  at night; if POST is audible from a bedroom, the runbook moves the wake to the evening. TrueNAS runs it as a post-init script;
  `ipmitool` is included.

---

## The quality bar

Every phase ends at this bar, not at "it works":

- **One name per thing.** A volume, a dataset, a share, a user and a DNS name
  say what they hold. No `-restored`, `-new`, `-old`, `-r730xd` suffixes.
- **No orphans.** Anything that no longer has a reason is deleted in the same
  change that removed the reason — backups, exports, keys, users, DNS records,
  healthchecks, dashboards.
- **One mechanism per job.** History lives in the vault. Retention runs in one
  place per tier. Nothing is covered twice by accident.
- **Every exemption is a line in git.** Tier-3 volumes are in group `none`
  because a manifest says so.
- **Docs describe what is, not what was.** Plans get deleted when executed;
  host READMEs are rewritten, not appended to.

## Phase 0 — answer before starting

| Question | How | Changes |
|---|---|---|
| **Synology Office / Calendar / Contacts** cover what Nextcloud does for 3 users? | install, open a real `.docx`; check what vicky actually uses | whether Nextcloud can go at all |
| Mini PC: CPU, RAM ≥ 16 GB, SSD with PLP? | inspect | if no SSD: detach one D3-S4510 from `rpool` and move it |
| Extended SMART on both NAS disks | DSM → Storage Manager → HDD → S.M.A.R.T. Test, ~5 h | any error → buy disks before phase 3 |
| Mini PC disk ≥ 256 GB | inspect | Longhorn holds 77 GiB real / 202 GiB provisioned per node |
| DSM accepts a **non-admin** SFTP upload (pfSense) and rsync push (VPS) | one test user, one file each | no → the producer writes via the rsync service instead |
| iDRAC reachable for IPMI power-on from pve-3? | `ipmitool -I lanplus -H <idrac> chassis status` | the wake mechanism |
| `documents/` (16 G with no other copy) | [synology/README.md](../synology/README.md), section `documents/` | must be resolved before `NetBackup` is deleted |

---

## Phases

Each phase can stop safely. Nothing is deleted until its replacement has passed
its gate.

### 1 — NUT and heartbeat → pve-1; etcd snapshot removed · ~2 h

UPS USB to pve-1 (done 2026-09-29), new `upsd.users`, R730xd becomes a
secondary, `nut-exporter` reads `.254`. **Rename the UPS from `cyberpower` to `ups`** while
it moves: DSM's UPS client hardcodes the UPS name `ups`, the user `monuser` and
the password `secret`, and none of the three can be changed. Add that user to
`upsd.users` as a secondary. The rename touches every secondary's `MONITOR` line,
`nut-exporter`'s target and any Grafana query that names the UPS. Move `heartbeat-ping.sh` to pve-1. Delete `etcd-snapshot.sh`: three etcd members
rebuild each other, and a total loss is a DR rebuild anyway.

**Gate:** `upsc` answers on pve-1, the Grafana UPS panels keep their series, the
heartbeat stays green through a pve-2 reboot, DSM shows the UPS.

### 2 — `kubernetes-2` → mini PC · ~4 h

In-place replacement, **same name and IP** (`kubernetes-2`, `.82`), so nothing
else in the repo changes. Safe because Longhorn keeps **3 replicas on 3
schedulable nodes** (checked 2026-09-28) — two survive while the third node is
away.

Drain `kubernetes-2` → remove its etcd member → delete VM 811 → Proxmox on the
mini PC → VM via Terraform with the new MAC → apply the Talos config → Longhorn
rebuilds the third replica. Per [talos/THREE-NODE.md](../talos/THREE-NODE.md). Fix the DR guard's 3-vs-1 mismatch in
the same change (`terraform.tfvars` MACs).

**Gate:** three nodes `Ready` in three chassis, Longhorn all `Healthy`,
`task dr:verify` green.

### 3 — NAS becomes primary · ~3 h

Remove DSM's scheduled poweroff/wake and HDD hibernation. Delete
`NetBackup/vm-backups`. Create three shares:

| Share | Holds | NFS clients |
|---|---|---|
| `media` | `library/` + `downloads/` — **one share**, or ARR loses hardlinks | k8s nodes, per IP |
| `backups` | landing: `longhorn/`, `etcd/`, `immich-postgres/`, `pfsense/`, `oracle-vps/` | k8s nodes + pve-3, per IP |
| `homes` | Synology Drive (*My Drive* lives in each user's home) | — |

Per-host NFS rules, never the `/24`. DSM "Squash: no mapping" is the
`no_root_squash` equivalent — test it against `fsGroupChangePolicy` one export
at a time, as the pve-2 README warns.

**Gate:** a k8s node mounts both exports and writes as the pod user.

### 4 — Producers write to the NAS, Longhorn starts clean · ~8 h

**One rule for the landing: it holds the latest, history lives in the vault.**
Producers overwrite; nothing on the NAS prunes anything. The vault's daily
snapshots (30 daily, 12 monthly) are the only history, in one place, with one
retention. That deletes every per-producer prune: pfSense's receiver, the etcd
script's, the Immich CronJob's 30 days.

| Producer | Writes | How |
|---|---|---|
| Immich `pg_dump` | `backups/immich-postgres/latest.sql.gz` | NFS, `NFS_SERVER` → NAS |
| pfSense | `backups/pfsense/config.xml.gz` | SFTP, DSM user `pfsense`, write on that folder only |
| VPS | `backups/oracle-vps/` | DSM user `vps`, write on that folder only |
| Longhorn | `backups/longhorn/` | Garage |

Verified in phase 0 (2026-09-29), and not obvious:

- **Keys need root once.** sshd refuses a key unless `authorized_keys` is owned
  by the user and the home is not world-writable; DSM creates homes `777`.
  `sudo install -o <user> -m 600 …` plus `chmod 755` on the home. Both users
  already carry their real keys (`pfsense-backup`, `vps-backup`), restricted to
  `from="10.57.57.1"` — every producer arrives from pfSense's address.
- **rsync over SSH needs the full path**: `vps@nas:/volume1/backups/oracle-vps/`.
  `/backups/…` is read as an rsync module and fails with no message.
- **`rsync -a` replaces DSM's ACLs with Unix modes.** A `0600` file from the VPS
  then becomes unreadable to `vault-pull`. Push with
  `--no-perms --no-owner --no-group --chmod=D755,F644`.
- **pfSense's `scp -O` (legacy SCP) will not work** for a non-admin user. Drop
  `-O`; plain `scp` uses SFTP, tested.
- **The tailnet policy gates the VPS**, not pfSense: `tag:vps-proxy` needed
  `10.57.57.201:22`. Added 2026-09-29, with five dead grants removed.

One DSM user per producer, none in `administrators`. That replaces every
`rrsync` forced-command line with DSM's permission model. pve-2 keeps receiving
in parallel until phase 7.

#### Garage on pve-3

LXC, provisioned by the existing role (playbook renamed `garage-setup.yml`).
pve-3 mounts `backups/longhorn` over NFS; the LXC bind-mounts **a subdirectory
that exists only on the NAS** (`…/longhorn/data`). If the NFS mount is missing,
the bind source does not exist and Proxmox refuses to start the container —
instead of Garage silently writing into pve-3's root disk. Meta stays on pve-3's
NVMe. Garage's docs want meta on fast local storage and say nothing against
data on a network filesystem.

#### The Longhorn cut-over is the clean-up

The backup store today holds **22 backup volumes for the 10 volumes actually backed up**:

| Found 2026-09-28 | Count | Action |
|---|---|---|
| Backups of deleted volumes (`immich-postgres-restored`, `jellyfin-public-restored`, `radarr-public-restored`) | 3 | not carried over |
| Empty backup-volume entries for tier-3 volumes (caches, Prometheus, Loki, Grafana, netboot) | 9 | not carried over |
| Live volumes named `*-restored` from the DR drill (9), or `pvc-<uuid>` (Immich's Postgres) | 10 | renamed to the app name |
| Recurring-job group `media` meaning "back this up", `default` meaning "don't" | 2 | renamed `backup` / `none` |

The new Garage starts with an **empty bucket**. The old store is already on the
vault-to-be; it is kept 30 days and then deleted. Sequence:

1. Tier-3 caches (`jellyfin-cache`, `radarr-cache`, `sonarr-cache`,
   `jellyseerr-cache`) → `emptyDir`. They leave Longhorn entirely.
2. Recurring groups renamed: `backup` (tier 1-2), `none` (tier 3). Every
   volume carries exactly one.
3. Backup target → new Garage. Run the `backup` job once.
4. Per app, one at a time: scale to 0 → restore its fresh backup as
   `<app>` (`immich-library`, `immich-postgres`, `jellyfin`, …) → point the
   static PV in `restore-pvs` at it → scale up → delete the `*-restored`
   volume. ~10 min of downtime per app.
5. `restore-pvs/` becomes `volumes/` — it is the list of named volumes, not a
   restore artefact.

**End state:** the backup store lists exactly the tier-1/2 volumes, each under
its app's name, with the retention of one job. Nothing else.

**Gate:** one night lands everything on the NAS. `kubectl get backupvolumes`
equals the list in `volumes/`. A restore of one volume from the new Garage is
actually run.

### 5 — Media → NAS · ~4 h, mostly copy

1.19 T over 1 GbE ≈ 3-4 h. `rsync -aH` (hardlinks), then flip `NFS_SERVER` in
`kubernetes/components/common/cluster-vars.yaml`. `public/library` alongside.
⚠️ A node that mounted before a fix caches the broken view — `talosctl reboot`.

**Gate:** Jellyfin plays, an ARR import is a hardlink (`stat` link count 2),
qBittorrent seeds.

### 6 — Nextcloud → Synology Drive · ~4 h + 48 h parallel

Create 3 DSM users, copy the files out of Nextcloud's datadir, set up Drive
clients and phone apps, calendar/contacts if used. Remote access over the
Tailscale package already on the NAS — not a tunnel to DSM's login page.
Keep Nextcloud running read-only for 48 hours (decided 2026-09-29; the last
borg archive stays in the vault for 90 days as the safety net).

**Then:** keep the last borg archive in the vault for 90 days, delete VM 1000,
the tunnel, the Cloudflare DNS record, the Nextcloud manifests.

**Gate:** all three users have used Drive for 48 hours without falling back.

### 7 — R730xd → TrueNAS vault · ~6 h

Step by step in **[plan-truenas-vault.md](plan-truenas-vault.md)**: install,
pool import (`media` → `vault`, no copy needed), datasets, credentials, the
nightly chain, wake from pve-3, monitoring, restores, and every scheduled job
before → after.

Summary: woken nightly from pve-3 over IPMI, pull read-only from the NAS,
snapshot, restic to Oracle, power off when done — ~40 min a night, longer on
the first Sunday for scrub and SMART long. No spin-down, no shares, no apps.

**Gate:** seven nights in a row with zero intervention.

### 8 — Cleanup · ~3 h

Delete from git what phase 7 retired (table above). Rewrite
[architecture.md](architecture.md) (hosts, funnel diagram, "what runs where"),
[DR.md](../DR.md), `proxmox/pve-2/` → `truenas/`, [synology/README.md](../synology/README.md).
Update the healthchecks, Homepage, Grafana tiles that name pve-2.

---

## Estimate

~34 h of work, 2-3 weeks in the calendar; the vault's seven-night gate is the
longest wait. Order is fixed by
dependencies: 1 → 2 → 3 → (4, 5, 6 in any order) → 7 → 8.

## Power, rough

| | Today | After |
|---|---|---|
| R730xd | ~112 W × 24 h ≈ 2.7 kWh/day | ~100 W × 1 h + ~12 W (iDRAC) × 23 h ≈ 0.4 |
| DS223 + 2× RE4 | asleep most of the week | ~25 W × 24 h ≈ 0.6 |
| mini PC | off | ~10-15 W ≈ 0.3 |
| **Net** | | **≈ −1.4 kWh/day, ~40 kWh/month** |

Only the 112 W is measured. Measure the rest before quoting a saving.

## Still open, not in this plan

**Retiring the R730xd.** If the vault role is all that is left, a mini PC with
two large disks does it at ~10 W. The R730xd's case is that it already holds
4.3 TiB free, has a BMC, and costs nothing to keep. Deliberated 2026-08-27,
postponed; this plan makes the question easier, not different.
