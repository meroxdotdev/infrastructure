# Runbook — the R730xd as a TrueNAS vault

Phase 7 of [plan-nas-hot-r730-cold.md](plan-nas-hot-r730-cold.md), step by
step. Written 2026-09-28, not started.

**Precondition:** phases 1-6 of that plan are done. `pve-2` holds no role: no
k8s node, no NFS client, no Nextcloud, no Garage, no NUT, no heartbeat. If any
of that is still true, stop here.

---

## What the vault is

A machine that is off unless it is copying. It wakes, pulls from the NAS,
snapshots, pushes restic to Oracle, and powers itself off. It exports nothing
but one SMB share, `files`, to the workstation only.

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
| Exposure | Powered off ~22 h/day. SMB only for `files`, only from the workstation; `backup` and `system` are never shared. No NFS, iSCSI or S3 | nothing to attack most of the day; the machine copies are not reachable at all |
| History | Native periodic snapshots, 30 daily + 12 monthly, retention by TrueNAS | an encrypted NAS gets pulled as a new version; the clean ones stay |
| Blast radius | `rsync --max-delete=500`: past 500 deletions rsync stops deleting and exits 25 | a wiped or renamed-by-ransomware source is not mirrored; healthchecks alerts |
| Off-site | restic to `rest-server --append-only`; retention runs on the VPS | even a fully compromised vault cannot delete Oracle's history |

Deliberately not used: `zfs hold` on routine snapshots — a held snapshot is
exempt from retention and piles up until released by hand; holds are for a
one-off snapshot before a risky change. TrueNAS 26's *Ransomware Defender* is
still in development; revisit when it ships.

### Layout

Four top-level datasets, split by who writes them:

```
vault/
├── backup/   written only by the nightly run, never shared
│   ├── nas/      pull of the NAS: backups/ (Longhorn, pfSense, VPS), homes/ (Drive)
│   └── github/   git mirrors of the repositories
├── files/    yours, over SMB: Personal/ Job/ Clients/ Lab/ — the Drive layout;
│             Personal/Movies holds three films for when the NAS is down
└── system/   scripts, restic binary, secrets (0700), config exports, logs, HOLD
```

`files` is yours: SMB from the workstation, TrueNAS apps and VMs with host
paths inside it and nowhere else. They are available only while the
vault is awake — anything that must run all the time belongs on the mini PCs.

Powering it on by hand is safe: answer **Keep on** to the Telegram question
(see [the gate](#6--the-nightly-chain)) and it stays up. While it is up, the
IPMI power-on at `W` is a no-op and the daily run starts from cron instead, so
the backups happen next to whatever you are doing.

### Why ~40 minutes, not 2-3 hours or 6-8

| Step | Time, steady state |
|---|---|
| POST | 4-6 min measured on Proxmox; ~2-3 min after the fast-POST settings in step 1 |
| TrueNAS boot, pool import, middleware ready | ~2-3 min |
| rsync pull, one day of delta | a few min — today's weekly pull of the same set is 45 s–3 min |
| snapshot | seconds |
| restic → Oracle | ~5-10 min, dominated by `restic check` |
| **Boot budget** | **10 min** from `W` to the chain's start ping, whatever POST measures — a slow POST is not an alert |
| **Daily total** | **~30-35 min; planned as 45** |
| Monthly: scrub ~1.5 T on 12 disks | ~1.5-2 h |
| Monthly: SMART long test, 600 GB 10k SAS, all disks in parallel | ~1.5 h, runs beside the scrub |

Time on costs watts and buys no safety. The window ends when the work does, not
at a clock time — see [the chain](#6--the-nightly-chain).

### When

**Wake at `W`**, a local time kept in `vault/system/PRIVATE-NOTES.md` and not in
this public repository — the hours a machine holding the offline copies is
reachable are the one thing worth hiding about it. `W` must fall after every
producer has finished in both seasons; the UTC-scheduled
ones (Longhorn, VPS) move *earlier* in winter, never later. The
UTC-vs-EEST problem does not exist in this design.

If the fans at POST are audible from a bedroom, move `W` to the evening. That
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
- [ ] iDRAC: *IPMI over LAN* enabled, a new user `vaultwake` with **Operator**
      privilege, password in the password manager. Test from pve-3:
      `ipmitool -I lanplus -H <idrac> -U vaultwake -L OPERATOR -f /root/.ipmi-vaultwake chassis status`.
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
   - **Fast, unattended POST** — every minute of POST is a minute of loud fans:
     - System Memory Testing → **Disabled**;
     - *F1/F2 Prompt on Error* → **Disabled**, so a warning never leaves the
       vault waiting at a prompt until the backstop;
     - every NIC's boot protocol → **None** (no PXE attempt);
     - boot sequence → the two boot SSDs only;
     - iDRAC → Lifecycle Controller → *Collect System Inventory on Restart* →
       **Disabled** (the largest single saving, ~1-2 min).
   - Leave the H730P in **HBA** personality — it already is, all 14 disks are
     JBOD. TrueNAS sees them directly; `smartctl` already reads the SAS disks
     through it today. The TrueNAS forum rates this controller in HBA mode as
     working, not ideal — no action needed unless SMART tests fail in step 7.
4. Note the MAC of the port in use (`eno4`, BCM57800 rNDC) — same cable, same port.

## 2 — Install · ~30 min

1. Download the TrueNAS SCALE ISO, verify the SHA256.
2. iDRAC → Virtual Media → map ISO → boot once from virtual CD (F11).
3. Installer: target = **both SSDs** (boot-pool mirror). Do **not** select any
   SAS disk.
4. Admin user `truenas_admin`, password in the password manager.
5. Reboot, remove media.
6. Console menu → network: `eno4` static `10.57.57.250/24`, gateway
   `10.57.57.1`, DNS `10.57.57.1`, hostname `vault`.

## 3 — Pool · ~2 h, mostly the SMART test

**Created fresh, not imported** (decided 2026-10-02). Everything on the old
`media` pool exists elsewhere: the dated pfSense/VPS history and `tools/n8n` in
Oracle's restic snapshot of 2026-09-30, the three films on the NAS.

1. **SMART long test on all 12 SAS disks first**, in parallel, ~70 min.
   TrueNAS 25.10 removed SMART tests from the UI; System → Shell:
   `for d in $(lsblk -dno NAME,MODEL | awk '/AL14SEB|HUC1018/{print $1}'); do sudo smartctl -t long /dev/$d; done`. Any disk with a failed test,
   pending or reallocated sectors, or grown defects stays out of the pool.
2. Storage → Create Pool `vault`:
   - Data: **one RAIDZ3 vdev of 12 disks** (11× Toshiba AL14SEB060N, 1× HGST
     HUC101860CSS204 — same size, mixing is fine);
   - **Encryption on**, key-based (auto-unlock at boot). Download the key file
     at once and store it in Passwords as `TrueNAS — vault pool key`;
   - no cache, log, special or spare vdevs.

Why RAIDZ3 × 12 and not 2× RAIDZ2 × 6: any three disks can fail, not "two per
group"; 5.4 TB usable instead of 4.8; one vdev. The usual arguments against a
wide RAIDZ3 do not apply here: resilvering 600 GB disks takes 1-2 h, not days,
and the extra IOPS of two vdevs are invisible behind a 1 GbE link. dRAID is
for vdevs with 10+ data disks per group and is not recommended by TrueNAS at
this size.

Why no hot spare: a spare only acts while the host is on, and the vault is off
~22 h a day; it would spin and wear for nothing. One **cold spare** (an
AL14SEB060N) sits in a drawer instead. A failed-disk alert means: wake the
vault, swap the disk, `zpool replace`, keep it on (`HOLD`) until the resilver
finishes.

Why encryption: a failed disk can be thrown away and the server sold without
wiping 12 disks. The key is auto-unlocked, so the nightly run stays unattended.

Pool settings: `compression=lz4` (default), `atime=off`.

## 4 — Datasets · ~15 min

Created in the UI (Datasets → Add Dataset), children inherit the pool's
encryption. The three films are copied from the NAS into `files/Personal/Movies` by
hand once SMB is up; `tools/n8n` is restored from Oracle only if ever needed.

| Dataset | Holds | Snapshots | In restic |
|---|---|---|---|
| `vault/backup` | `nas/` (pull of NAS `backups/` and `homes/`), `github/` (mirrors) | 30 daily + 12 monthly | yes |
| `vault/files` | yours over SMB: `Personal/`, `Job/`, `Clients/`, `Lab/` — the Drive layout | 30 daily | yes, **except `Personal/Movies/` and `Personal/VMs/`** — the automotive VMs (49 GB) moved off the NAS 2026-10-02 and live on the vault only |
| `vault/system` | scripts, restic binary, secrets (0700), config exports, logs | 30 daily | yes, **except `secrets/`** |

Three datasets, one per writer (the nightly run, you, the scripts), because
snapshots and retention are set per dataset. Everything finer is a folder.

Record size: `1M` on `backup` and `files` (large sequential files);
default elsewhere.

## 5 — Credentials · ~30 min

| Credential | Where on the vault | Purpose |
|---|---|---|
| rsync account `vault-pull` | `vault/system/secrets/rsync-password` | pull from NAS |
| restic repo password | `vault/system/secrets/restic-password` | decrypt/encrypt |
| rest-server credential | `vault/system/secrets/rest-password` | auth to Oracle |
| healthchecks.io URL | `vault/system/secrets/hc-vault` | dead-man's switch |
| Telegram bot | TrueNAS Alert Service | pool/SMART/scrub alerts |

All five in the password manager too. `chmod 600`, owner root.

**On the NAS (DSM):** the pull uses DSM's **rsync service** (daemon, port
873), not SSH. DSM allows SSH logins only to administrators; the rsync service
works for ordinary users, and share permissions make it read-only.

1. User `vault-pull`, **not** in `administrators`, strong password.
2. Shared folders: **read-only** on `backups`, `homes`. Nothing else — the
   media library is not copied.
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
keep `pve-2` until the first `vault` snapshot exists, then remove it.

**Done 2026-10-02**, the day the vault went live, at the owner's request
rather than after the gate: every snapshot not from `vault` (13, hosts `pve`
and `pve-2`) forgotten and pruned on the VPS, 61 GiB freed, `check` clean; the
`pve-2` rest-server user removed. The repository holds only the vault's history. Same
repository, same repo password — content-defined chunking means the first push
from new paths uploads almost nothing.

**Nothing on the NAS reaches the vault.** Verify: the vault's
`/root/.ssh/authorized_keys` and `truenas_admin`'s are empty except your
workstation.

## 6 — The nightly chain

One script, in git at `truenas/scripts/vault-nightly.sh`, copied to
`/mnt/vault/system/scripts/`. Not on the root filesystem — TrueNAS replaces it
on every update.

**Started by the boot, not by the clock.** A POSTINIT init script (System →
Advanced → Init/Shutdown Scripts) starts it in the background once the pool
is imported. Boot time varies by minutes; a cron at a fixed offset would
either wait for nothing or start before the pool is there. Every boot runs
the chain — a manual power-on included, which is harmless: it is one more
backup, and the gate below asks before powering off.

A host kept on past a day never boots at `W`, so a TrueNAS cron job at **`W` +
10 min** starts the chain too. A lock file and a "ran today" stamp in
`vault/system` make the two triggers one run per day.

```
1. start ping → healthchecks.io
2. rsync pull (rsync://) NAS backups, homes → vault/backup/nas/{backups,homes}
     -aH --delete --max-delete=500 --numeric-ids ; exit 25 = stop, alert, no snapshot
3. git mirror refresh → vault/backup/github
4. TrueNAS config export → vault/system/config/     (midclt call config.save)
5. snapshots: midclt call pool.snapshottask.run <id> for each task
6. restic backup vault/{backup,personal,work,system} → Oracle, host=vault,
     excludes per the dataset table
7. restic check (read 5 % of data)
8. 1st of month: restore drill — restore pfsense + oracle-vps, hash-compare
9. success ping → healthchecks.io   (or fail ping with the step that failed)
10. power-off gate
```

The **power-off gate** — shut down only when all of these hold:

- no file `/mnt/vault/system/HOLD` (manual work — see [Restores](#restores))
- **you said nothing**: every time, 5 min before, Telegram asks "vault shuts
  down at hh:mm" with two buttons:
  - **Keep on** → creates `HOLD` with an expiry: it stays up until the next
    day's run, which asks again. Unanswered then, it powers off by itself.
  - **Shut down now** → powers off immediately.

  Silence means shut down: a missed message never leaves the vault on.
  To power off a held vault early: TrueNAS UI → Power → Shut Down. The homelab
  bot is shared with Alertmanager and n8n, which only send; the gate is its
  only reader, and a webhook added later would break the buttons.
- no scrub running — past `W` + 2 h, `zpool scrub -p` pauses it; it resumes
  on the next boot, so a long scrub spreads over several nights by itself
- no resilver running — a replaced disk resilvers to the end, however long
- no SMART self-test running — past `W` + 2 h, let it abort; TrueNAS alerts on the
  missed test and the next month retries

then `midclt call system.shutdown`.

A TrueNAS cron job at **`W` + 3 h** runs the gate alone — the backstop if
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

Pin restic as a static binary in `vault/system/bin/restic` (checksum in git).
Do not depend on whatever TrueNAS ships.

## 7 — TrueNAS built-in tasks · ~15 min

| Task | Setting |
|---|---|
| Periodic snapshot × 5 | per the dataset table; schedule **disabled**, run by the chain (step 5); retention by TrueNAS |
| Scrub `vault` | first Sunday, `W` + 10 min |
| S.M.A.R.T. | Not in the 25.10 UI any more. Cron job (System → Advanced → Cron Jobs), first Sunday `W` + 10 min: `midclt call disk.smart_test LONG '["*"]'` — the form TrueNAS's own migration of old SMART tasks produces |
| Alert services | Telegram; level WARNING+ |
| Init scripts | POSTINIT: `fan-control.sh` first, then `vault-nightly.sh` in the background, both from `/mnt/vault/system/scripts/` (from `proxmox/pve-2/scripts/`, `ipmitool` is in TrueNAS) |
| SSH service | on, key-only, root login off |
| SMB | one share, `files`, *Hosts Allow* = the workstation |
| NFS / iSCSI / S3 | **off** |
| Apps, VMs | allowed, host paths only under `vault/files` |
| Allowed IP Addresses | the workstation only (System → General). Pin its address first: pfSense DHCP reservation, and *Private Wi-Fi Address* off for the home network — pfSense already holds three rules for the same MacBook under rotated addresses |
| Admin 2FA | on |

`pool.snapshottask.run <id>` exists in the TrueNAS API. Untested: whether it runs
a task whose schedule is disabled. If not, give each task a schedule inside the
window (`W` + 90 min) — the chain's run comes first, and the later scheduled one only
adds a snapshot of the same state.

## 8 — Wake from pve-3 · ~10 min

```
# /etc/cron.d/vault-wake on pve-3 — in git under proxmox/pve-3/etc/
M H * * *  root  ipmitool -I lanplus -H <idrac> -U vaultwake -L OPERATOR -f /root/.ipmi-vaultwake chassis power on
```

`M H` is `W`, filled in on pve-3 only: the line in git stays a placeholder and
the real one lives in `/etc/cron.d/vault-wake` there.

`-L OPERATOR` is required: ipmitool asks for an Administrator session by
default, which iDRAC refuses to an Operator user.

`chassis power on` on an already-running host is a no-op, so a manual session
is never cut short.

Manual wake: same command, or iDRAC → Power → On.

## 9 — Monitoring · ~30 min

| Remove | Add |
|---|---|
| Prometheus targets on `10.57.57.250` (node_exporter, pve-exporter pve-2) | healthchecks `vault-nightly`: cron schedule `W`, grace **60 min** — a vault that did not wake, or a run that failed, is known within the hour |
| healthchecks `pve-push-synology`, `nightly-checks`, `restic-push` (pve-2) | — (one check is enough: a vault left on costs watts, not data, and the backstop at `W` + 3 h powers it off) |
| UPS panels bound to pve-2 | TrueNAS → Telegram for pool/SMART/scrub |

Rule 4 of [architecture.md](architecture.md) applies: an alert that assumes a
24/7 host will fire every day and teach you to ignore it. Delete it; do not
silence it.

## 10 — Gate

Seven consecutive days: wakes at `W`, `vault-nightly` green, `restic
snapshots --host vault` shows a new snapshot, the host is off by `W` + 1 h
(`W` + 4 h on the first Sunday), zero manual steps. Then the first monthly day with
scrub and SMART long completes or pauses cleanly.

---

## Restores

Manual on purpose. The vault holds no write credential into the NAS, and that
stays true.

**Keep it awake first:** wake it, then answer **Keep on** (or `touch
/mnt/vault/system/HOLD` by hand). When done, shut it down from the UI — or leave
it, and the next day's run asks again.

| Lost | From | How |
|---|---|---|
| A file, a folder | vault snapshot | `/mnt/vault/backup/nas/.zfs/snapshot/<name>/homes/…` → `scp` to the Mac → put it back through Drive |
| A Longhorn volume | Garage on the NAS | Longhorn UI → Backup → Restore — the vault is not involved |
| Garage's store itself | vault | `rsync` `vault/backup/nas/backups/longhorn/` → NAS as the DSM admin, restart Garage, restore in Longhorn |
| The NAS entirely | vault | new disks → DSM → shares per plan phase 3 → `rsync` each dataset back as admin |
| The vault and the NAS | Oracle | `restic restore` on any machine, or on the VPS per [proxmox/pve-2/README.md](../proxmox/pve-2/README.md#pve-2--oracle-restic) — the three films are lost; the NAS library was never copied |
| The vault's OS | anywhere | reinstall, import `vault`, upload `vault/system/config/latest.db`, reapply `system/secrets` |

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
| vzdump VM 1000 | pve-2 Sat 22:00 | — | **deleted** 2026-09-30 with Nextcloud |
| NUT primary | pve-2 | pve-1 | moved 2026-09-29 |
| Nextcloud borg | VM 1000 02:40 | — | **deleted** 2026-09-30 |
| Longhorn backup | k8s 02:50 | unchanged | target = Garage on NAS |
| Longhorn snapshot / system-backup | k8s */6 h, Mon 01:30 | unchanged | — |
| Immich `pg_dump` | k8s 03:02 | — | **deleted** 2026-09-30 with Immich |
| pfSense config push | pfSense 03:00 | unchanged | → NAS `backups/pfsense`, script `backup.sh` (done 2026-09-29) |
| VPS backup wrapper | VPS 02:45 | unchanged | → NAS `backups/oracle-vps` |
| VPS restore drill, restic retention | VPS | unchanged | — |
| NAS weekly pull `pull-from-pve2.sh` | DSM Task Scheduler | — | **deleted** |
| NAS RTC wake / scheduled poweroff | DSM | — | **deleted** |
| **Vault wake** | — | pve-3 at `W` | **new** |
| **Vault chain + gate** | — | vault POSTINIT, backstop cron `W` + 3 h | **new** |

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
