# Runbook — the R730xd as a TrueNAS vault

Phase 7 of [plan-nas-hot-r730-cold.md](plan-nas-hot-r730-cold.md), step by
step. Written 2026-09-28, not started.

**Precondition:** phases 1-6 of that plan are done. `pve-2` holds no role: no
k8s node, no NFS client, no Nextcloud, no Garage, no NUT, no heartbeat. If any
of that is still true, stop here.

---

## What the vault is

A machine that is off unless it is copying. It wakes, pulls from the NAS,
snapshots, pushes restic to Oracle, and powers itself off. It serves nothing to
anyone and exports no share.

| | |
|---|---|
| OS | TrueNAS SCALE, Community Edition, current stable |
| Hostname / IP | `vault`, `10.57.57.250` — reused, so pfSense, DNS and the iDRAC notes stay valid |
| Pool | `vault` = today's `media`, imported and renamed (2× RAIDZ2-6, 12× 600 GB SAS) |
| Boot | the two Intel D3-S4510 960 GB, mirrored — or one, if the other went to the mini PC |
| Awake | daily ~40 min; first Sunday of the month ~3-4 h |
| Disks | **no spin-down.** They spin for the window and stop with the host |

### How it resists ransomware

Only stock mechanisms. No custom detection, nothing that has to be maintained
to stay safe.

| Layer | Mechanism | What it stops |
|---|---|---|
| Reachability | Pull-only: no host holds a credential into the vault. TrueNAS *Allowed IP Addresses* limits UI and SSH to the workstation. 2FA on the admin | a compromised NAS, node or VPS cannot touch the vault |
| Exposure | Powered off ~22 h/day. No SMB, NFS, iSCSI or S3 service | nothing to attack most of the day, nothing to mount the rest |
| History | Native periodic snapshots, 30 daily + 12 monthly, retention by TrueNAS | an encrypted NAS gets pulled as a new version; the clean ones stay |
| Blast radius | `rsync --max-delete=500`: past 500 deletions rsync stops deleting and exits 25 | a wiped or renamed-by-ransomware source is not mirrored; healthchecks alerts |
| Off-site | restic to `rest-server --append-only`; retention runs on the VPS | even a fully compromised vault cannot delete Oracle's history |

Deliberately not used: `zfs hold` on routine snapshots — a held snapshot is
exempt from retention and piles up until released by hand; holds are for a
one-off snapshot before a risky change. TrueNAS 26's *Ransomware Defender* is
still in development; revisit when it ships.

### Your own tests on the vault

Everything experimental lives in `vault/lab`: VMs, apps, scratch data. Apps are
allowed there and only there; no app gets a host path outside `vault/lab`. The
backup datasets are written by one thing, the nightly pull.

Powering it on by hand is safe: `touch /mnt/vault/ops/HOLD` keeps it up past
the nightly run, and the 04:00 IPMI power-on is a no-op on a running host, so
the nightly run happens next to whatever is being tested.

### Why ~40 minutes, not 2-3 hours or 6-8

| Step | Time, steady state |
|---|---|
| POST | 4-6 min (R730xd, measured on every reboot so far) |
| rsync pull, one day of delta | a few min — today's weekly pull of the same set is 45 s–3 min |
| snapshot | seconds |
| restic → Oracle | ~5-10 min, dominated by `restic check` |
| **Daily total** | **~20-30 min, round to 40** |
| Monthly: scrub ~1.5 T on 12 disks | ~1.5-2 h |
| Monthly: SMART long test, 600 GB 10k SAS, all disks in parallel | ~1.5 h, runs beside the scrub |

Time on costs watts and buys no safety. The window ends when the work does, not
at a clock time — see [the chain](#6--the-nightly-chain).

### When

**Wake at 04:00 local.** Every producer is done by then in both seasons: the
latest is pfSense at 03:00, and the UTC-scheduled
ones (Longhorn, Immich, VPS) move *earlier* in winter, never later. The
UTC-vs-EEST problem does not exist in this design.

If the fans at POST are audible from a bedroom, move the wake to 19:00. That
pulls the night before's backups, i.e. an RPO of ~16 h instead of ~1 h.

---

## 0 — Before touching the R730xd

- [ ] Last restic run from pve-2 succeeded; `restic snapshots` on the VPS shows it.
- [ ] Copied off pve-2 to the Mac, then into the password manager where they
      are secrets: `/root/PRIVATE-NOTES.md`, `/root/.restic-oracle-password`,
      `/root/.restic-rest-password`, the healthchecks.io URLs from
      `/root/scripts/*.sh`, the Telegram bot token and chat id.
- [ ] Every item from `/media/backups` is also on the NAS under `backups/`
      (phase 4 gate). `diff <(ls /media/backups) <(ls on NAS)`.
- [ ] Kali VM 106: `vzdump` to the NAS or accept losing it.
- [ ] iDRAC: *IPMI over LAN* enabled, a new user `vaultwake` with **Operator**
      privilege, password in the password manager. Test from pve-3:
      `ipmitool -I lanplus -H <idrac> -U vaultwake -E chassis status`.
- [ ] iDRAC virtual console opens (HTML5, firmware 2.84) — or have a USB stick
      and a monitor.

## 1 — Hardware and BIOS · ~30 min

1. Power off from Proxmox: `shutdown -h now`.
2. **Remove the Quadro P2200.** Nothing uses it; transcoding is on pve-1's
   iGPU. Idle watts while awake, and one less thing on the fan ladder.
3. BIOS (F2):
   - Boot mode UEFI.
   - *AC Power Recovery* → **Off**. After a power cut the vault must wait for
     its schedule, not come up by itself.
   - Leave the H730P in **HBA** personality — it already is, all 14 disks are
     JBOD. TrueNAS sees them directly; `smartctl` already reads the SAS disks
     through it today. The TrueNAS forum rates this controller in HBA mode as
     working, not ideal — no action needed unless SMART tests fail in step 7.
4. Note the MAC of the port in use (`eno1`, BCM57800) — same cable, same port.

## 2 — Install · ~30 min

1. Download the TrueNAS SCALE ISO, verify the SHA256.
2. iDRAC → Virtual Media → map ISO → boot once from virtual CD (F11).
3. Installer: target = **both SSDs** (boot-pool mirror). Do **not** select any
   SAS disk.
4. Admin user `truenas_admin`, password in the password manager.
5. Reboot, remove media.
6. Console menu → network: `eno1` static `10.57.57.250/24`, gateway
   `10.57.57.1`, DNS `10.57.57.1`, hostname `vault`.

## 3 — Pool · ~15 min

Import, not recreate. pve-2 runs OpenZFS 2.4.4; TrueNAS 26 ships OpenZFS 2.4,
so every feature is supported. On a 25.10 release (OpenZFS 2.3) import still
works: checked 2026-09-28, every **active** feature on `media` is pre-2.3, and
the 2.4 ones are only *enabled*, which does not block import.

```sh
# TrueNAS shell, as root
zpool import                        # must list "media", state ONLINE
zpool import media vault            # rename on import
zpool export vault                  # hand it to the middleware
```

Then UI → Storage → **Import Pool** → `vault`.

⚠️ Do **not** run *Upgrade Pool* when TrueNAS offers it. Nothing needs the new
features, and it removes the option of reading these disks from Proxmox again.

If import fails: the NAS already holds everything this pool holds. Wipe the 12
SAS disks, create `vault` as 2× RAIDZ2 of 6, and let the first pull repopulate
it (~4 h for the library over 1 GbE).

Pool settings: `compression=lz4` (inherited), `atime=off`.

## 4 — Datasets · ~15 min

Reuse what is there, rename, drop the rest.

| Dataset | From | Holds | Snapshots | In restic |
|---|---|---|---|---|
| `vault/backups` | `media/backups` | pull of NAS `backups/` | 30 daily + 12 monthly | yes |
| `vault/drive` | new | pull of NAS `homes/` (Synology Drive's *My Drive*) | 30 daily + 12 monthly | yes, **except `merox/VMs/`** (49 GB of VirtualBox images; Oracle has ~77 GiB) |
| `vault/library` | `media/library` | pull of NAS `media/library` | 7 daily (tier 3 — only against a bad `--delete`) | **no** — 1.2 T, Oracle has ~77 GiB |
| `vault/repos` | new | `git clone --mirror` of GitHub repos | 30 daily | yes |
| `vault/ops` | new | scripts, restic binary, secrets (0700), config exports, logs | 30 daily | yes, except `secrets/` |
| `vault/lab` | new | your tests: VMs, apps, scratch | none | **no** |

`vault/backups` and `vault/library` already have the right names after the pool
rename.

```sh
zfs destroy -r vault/isos                        # re-downloadable
# vault/photos (3.3 G) → confirm it is in Immich or on the NAS, then destroy
zfs destroy -r vault/backups/nextcloud          # only after the 90-day borg hold, see plan phase 6
zfs create vault/drive vault/repos vault/ops vault/lab
zfs set recordsize=1M vault/library vault/backups
```

Delete the old `daily-*` snapshots on `vault/backups` once the first TrueNAS
snapshot exists — the periodic task only prunes its own naming scheme.

## 5 — Credentials · ~30 min

| Credential | Where on the vault | Purpose |
|---|---|---|
| rsync account `vault-pull` | `vault/ops/secrets/rsync-password` | pull from NAS |
| restic repo password | `vault/ops/secrets/restic-password` | decrypt/encrypt |
| rest-server credential | `vault/ops/secrets/rest-password` | auth to Oracle |
| healthchecks.io URL | `vault/ops/secrets/hc-vault` | dead-man's switch |
| Telegram bot | TrueNAS Alert Service | pool/SMART/scrub alerts |

All five in the password manager too. `chmod 600`, owner root.

**On the NAS (DSM):** the pull uses DSM's **rsync service** (daemon, port
873), not SSH. DSM allows SSH logins only to administrators; the rsync service
works for ordinary users, and share permissions make it read-only.

1. User `vault-pull`, **not** in `administrators`, strong password.
2. Shared folders: **read-only** on `media`, `backups`, `homes`. Nothing else.
3. Control Panel → File Services → rsync → enable rsync service.
   Application Privileges → rsync → allow `vault-pull` only, from
   `10.57.57.250` only.
4. Test from the vault:
   `rsync --password-file=… -n -a rsync://vault-pull@10.57.57.201/backups/ /tmp/x/`
   lists files; a push to the same module fails.
5. Test that `homes` really yields **every** user's Drive files: compare the file
   count per user against DSM. Per-home ACLs can hide a user's folder even
   from a read grant on `homes`.

Unencrypted on the LAN, like the NFS mounts the cluster already uses. If that
is not acceptable, the fallback is an NFS export of the three shares,
read-only, to `10.57.57.250` only.

**On Oracle (rest-server):** add htpasswd user `vault` (`vps_backup` role),
keep `pve-2` until the first `vault` snapshot exists, then remove it. Same
repository, same repo password — content-defined chunking means the first push
from new paths uploads almost nothing.

**Nothing on the NAS reaches the vault.** Verify: the vault's
`/root/.ssh/authorized_keys` and `truenas_admin`'s are empty except your
workstation.

## 6 — The nightly chain

One script, in git at `truenas/scripts/vault-nightly.sh`, copied to
`/mnt/vault/ops/scripts/`. Run from the TrueNAS UI (System → Advanced → Cron
Jobs) as root, **04:05 daily**. Not on the root filesystem — TrueNAS replaces
it on every update.

```
1. start ping → healthchecks.io
2. rsync pull (rsync://) NAS backups, homes, media → vault/{backups,drive,library}
     -aH --delete --max-delete=500 --numeric-ids ; exit 25 = stop, alert, no snapshot
3. git mirror refresh → vault/repos
4. TrueNAS config export → vault/ops/config/        (midclt call config.save)
5. snapshots: midclt call pool.snapshottask.run <id> for each task
6. restic backup vault/{backups,drive,repos,ops} → Oracle, host=vault
7. restic check (read 5 % of data)
8. 1st of month: restore drill — restore pfsense + immich-postgres, hash-compare
9. success ping → healthchecks.io   (or fail ping with the step that failed)
10. power-off gate
```

The **power-off gate** — shut down only when all of these hold:

- no file `/mnt/vault/ops/HOLD` (manual work — see [Restores](#restores))
- no scrub running — past 06:00 local, `zpool scrub -p` pauses it; it resumes
  on the next boot, so a long scrub spreads over several nights by itself
- no SMART self-test running — past 06:00, let it abort; TrueNAS alerts on the
  missed test and the next month retries

then `midclt call system.shutdown`.

A second TrueNAS cron job at **07:00** runs the gate alone — the backstop if
step 2-8 hangs.

Why a script and not TrueNAS's own *Rsync Task*: in module mode the task has
no way to pass the password of a DSM rsync account, and DSM allows SSH only to
administrators, so neither of its modes can pull from the NAS as a read-only
user. The pieces the script calls — `rsync`, TrueNAS snapshot tasks via
`midclt`, `restic` — are each the standard tool for their job; the script only
orders them and stops at the first failure (`set -euo pipefail`).

Ported from pve-2, not rewritten: the restic flags, `--keep-within-*`
retention on the VPS, and the drill logic of `restic-restore-drill.sh`. Read
[proxmox/pve-2/scripts/](../proxmox/pve-2/scripts/) before writing, and keep
its guardrails.

Pin restic as a static binary in `vault/ops/bin/restic` (checksum in git).
Do not depend on whatever TrueNAS ships.

## 7 — TrueNAS built-in tasks · ~15 min

| Task | Setting |
|---|---|
| Periodic snapshot × 5 | per the dataset table; schedule **disabled**, run by the chain (step 5); retention by TrueNAS |
| Scrub `vault` | first Sunday, 04:10 |
| S.M.A.R.T. | SHORT weekly Sunday 04:10; LONG first Sunday 04:10 |
| Alert services | Telegram; level WARNING+ |
| Init script | POSTINIT: `/mnt/vault/ops/scripts/fan-control.sh` (from `proxmox/pve-2/scripts/`, `ipmitool` is in TrueNAS) |
| SSH service | on, key-only, root login off |
| NFS / SMB / iSCSI / S3 | **off** |
| Apps | allowed, host paths only under `vault/lab` |
| Allowed IP Addresses | the workstation only (System → General). Pin its address first: pfSense DHCP reservation, and *Private Wi-Fi Address* off for the home network — pfSense already holds three rules for the same MacBook under rotated addresses |
| Admin 2FA | on |

`pool.snapshottask.run <id>` exists in the TrueNAS API. Untested: whether it runs
a task whose schedule is disabled. If not, give each task a schedule inside the
window (05:30) — the chain's run comes first, and the later scheduled one only
adds a snapshot of the same state.

## 8 — Wake from pve-3 · ~10 min

```
# /etc/cron.d/vault-wake on pve-3 — in git under proxmox/pve-3/etc/
0 4 * * *  root  ipmitool -I lanplus -H <idrac> -U vaultwake -f /root/.ipmi-vaultwake chassis power on
```

`chassis power on` on an already-running host is a no-op, so a manual session
is never cut short.

Manual wake: same command, or iDRAC → Power → On.

## 9 — Monitoring · ~30 min

| Remove | Add |
|---|---|
| Prometheus targets on `10.57.57.250` (node_exporter, pve-exporter pve-2) | healthchecks `vault-nightly`: period 1 day, grace 4 h |
| healthchecks `pve-push-synology`, `nightly-checks`, `restic-push` (pve-2) | healthchecks `vault-offline`: pinged by the power-off gate — a vault that stays up past 08:00 is a failure too |
| UPS panels bound to pve-2 | TrueNAS → Telegram for pool/SMART/scrub |

Rule 4 of [architecture.md](architecture.md) applies: an alert that assumes a
24/7 host will fire every day and teach you to ignore it. Delete it; do not
silence it.

## 10 — Gate

Seven consecutive days: wakes at 04:00, `vault-nightly` green, `restic
snapshots --host vault` shows a new snapshot, the host is off by 05:00
(08:00 on the first Sunday), zero manual steps. Then the first monthly day with
scrub and SMART long completes or pauses cleanly.

---

## Restores

Manual on purpose. The vault holds no write credential into the NAS, and that
stays true.

**Keep it awake first:** wake it, then `touch /mnt/vault/ops/HOLD`. Remove the
file when done — the next night's gate powers it off.

| Lost | From | How |
|---|---|---|
| A file, a folder | vault snapshot | `/mnt/vault/drive/.zfs/snapshot/<name>/…` → `scp` to the Mac → put it back through Drive |
| A Longhorn volume | Garage on the NAS | Longhorn UI → Backup → Restore — the vault is not involved |
| Garage's store itself | vault | `rsync` `vault/backups/longhorn/` → NAS as the DSM admin, restart Garage, restore in Longhorn |
| The NAS entirely | vault | new disks → DSM → shares per plan phase 3 → `rsync` each dataset back as admin |
| The vault and the NAS | Oracle | `restic restore` on any machine, or on the VPS per [proxmox/pve-2/README.md](../proxmox/pve-2/README.md#pve-2--oracle-restic) — the library is lost (tier 3) |
| The vault's OS | anywhere | reinstall, import `vault`, upload `vault/ops/config/latest.db`, reapply `ops/secrets` |

Write-back always uses a **temporary** credential — the DSM admin over SSH,
typed, never stored on the vault.

---

## Every scheduled job, before → after

Local time, Europe/Bucharest. UTC jobs are shown with their summer local time.

| Job | Today | After | Change |
|---|---|---|---|
| `garage-meta-nightly-copy.sh` | pve-2 03:01 | — | **deleted** |
| `etcd-snapshot.sh` | pve-2 03:03 | — | **deleted** 2026-09-29: three members rebuild each other |
| `zfs-snapshot-backups.sh` | pve-2 03:05 | vault, chain step 5 | built-in task |
| `restic-push-oracle.sh` | pve-2 03:10 | vault, chain step 6 | ported |
| `nightly-checks.sh` → sas-health | pve-2 03:20 | TrueNAS SMART alerts | **deleted** |
| → spindown-drift | pve-2 | — | **deleted** |
| → git-drift | pve-2 | TrueNAS config export in restic | **deleted** |
| → vzdump-freshness | pve-2 | — | **deleted** (no VM) |
| `restic-restore-drill.sh` | pve-2 1st 05:00 | vault, chain step 8 | ported |
| `heartbeat-ping.sh` | pve-2 */5 | pve-1 */5 | moved 2026-09-29 |
| spin-down enforcer, `sas-*.sh` | pve-2 | — | **deleted** |
| `fan-control.sh` | pve-2 service | vault POSTINIT | moved |
| `media` scrub | pve-2 1st 03:40 | vault first Sunday | built-in |
| vzdump VM 1000 | pve-2 Sat 22:00 | — | **deleted** |
| NUT primary | pve-2 | pve-1 | moved 2026-09-29 |
| Nextcloud borg | VM 1000 02:40 | — | **deleted** |
| Longhorn backup | k8s 02:50 | unchanged | target = Garage on NAS |
| Longhorn snapshot / system-backup | k8s */6 h, Mon 01:30 | unchanged | — |
| Immich `pg_dump` | k8s 03:02 | unchanged | `NFS_SERVER` → NAS |
| pfSense config push | pfSense 03:00 | unchanged | → NAS `backups/pfsense`; rename script `backup-to-nas.sh` |
| VPS backup wrapper | VPS 02:45 | unchanged | → NAS `backups/oracle-vps` |
| VPS restore drill, restic retention | VPS | unchanged | — |
| NAS weekly pull `pull-from-pve2.sh` | DSM Task Scheduler | — | **deleted** |
| NAS RTC wake / scheduled poweroff | DSM | — | **deleted** |
| **Vault wake** | — | pve-3 04:00 | **new** |
| **Vault chain + gate** | — | vault 04:05, backstop 07:00 | **new** |

Net: 14 scripts and 7 cron lines on pve-2, plus 2 DSM tasks, become **one chain
script, one wake line, and built-in TrueNAS tasks**.

## In git after this

```
truenas/
├── README.md              what the vault is, the window, restores (this file, trimmed to state)
├── scripts/
│   ├── vault-nightly.sh
│   └── fan-control.sh     moved from proxmox/pve-2/scripts/
└── restic.sha256
proxmox/pve-3/etc/cron.d/vault-wake
```

`proxmox/pve-2/` is deleted once the gate passes — history keeps it.
