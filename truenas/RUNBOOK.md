# vault — design and rebuild

The R730xd as the offline copy, built 2026-10-02. [README.md](README.md) is
what is deployed; this page is why it is built this way and how to build it
again from bare hardware. Every pitfall met on the first build is in here, at
the step where it bites.

---

## What it is

A machine that is off unless it is copying. pve-3 wakes it at `W`; it pulls
from the NAS read-only, snapshots, pushes restic to Oracle, asks on Telegram,
and powers itself off. Nothing holds a credential into it.

| | |
|---|---|
| OS | TrueNAS 25.10 Community, update profile *Mission Critical* |
| Address | `vault`, `10.57.57.250` on `eno4`; iDRAC `10.57.57.249` |
| Boot | `boot-pool`, mirror of two Intel D3-S4510 960 GB |
| Pool | `vault`: one RAIDZ3 of 12× 600 GB 10k SAS, AES-256-GCM, key auto-unlocked |
| Awake | ~10 min a day; first Sunday of the month ~75 min more (SMART long) |

### How it resists ransomware

| Layer | Mechanism | What it stops |
|---|---|---|
| Reachability | Pull-only; nothing holds a credential into the vault | a compromised NAS, node or VPS cannot touch it |
| Exposure | Off ~22 h a day. One SMB share, `files`, to the workstation only; `backup` and `system` never shared | nothing to attack most of the day |
| History | TrueNAS snapshots, 30 daily (+ 12 monthly on `backup`) | an encrypted NAS is pulled as a new version; the clean ones stay |
| Blast radius | `rsync --max-delete=500` exits 25, the run stops before any snapshot | a wiped or renamed source is not mirrored |
| Off-site | restic to rest-server `--append-only`; retention runs on the VPS | even a compromised vault cannot delete Oracle's history |

### Why RAIDZ3 × 12, no hot spare, encrypted

- **RAIDZ3 × 12, not 2× RAIDZ2 × 6:** any three disks may fail, not "two per
  group"; 4.9 TiB usable instead of 4.4; one vdev. Resilvering a 600 GB disk
  takes 1-2 h, so the usual case against wide RAIDZ3 does not apply, and the
  IOPS of two vdevs are invisible behind 1 GbE. dRAID is for 10+ data disks
  per group.
- **No hot spare:** a spare only acts while the host is on, and this one is off
  most of the day. One cold spare (an AL14SEB060N) waits in a drawer.
- **Encrypted:** a dead disk can be binned and the server sold without wiping
  twelve disks. The key is auto-unlocked, so nights stay unattended.

The disks are 50-57 k hours old (2026-10-02). Two (`sdi`, `sdj` at the time)
log more delayed-but-corrected reads than the rest — zero grown defects and
zero uncorrected errors on all twelve, so they are watched, not replaced.

### Timing, measured

| Step | Time |
|---|---|
| `W` → TrueNAS up, run started | 2 min 44 s (fast-POST settings below) |
| Pull, mirrors, config, snapshots, restic, check | ~80 s on an ordinary day |
| Telegram question → power-off | 5 min |
| First Sunday: SMART long on all disks in parallel | ~70 min, the gate waits |

Nothing depends on how long the boot takes: the run starts when the boot
ends, the gate after the run. healthchecks expects success within an hour of
`W`; a boot slow enough to miss that is a broken server.

**`W` stays out of this repository** — the hours a machine holding the
offline copies is reachable are the one thing worth hiding about it. It lives
in `/mnt/vault/system/secrets/vault.env` and in `/etc/cron.d/vault-wake` on
pve-3, nowhere else.

---

## Rebuild

### 0 — Have at hand

- Password manager: restic repository password, TrueNAS pool key,
  `truenas_admin`, `vaultwake`, iDRAC root, `vault-pull`, `merox` (SMB).
- The TrueNAS ISO (current Community release), SHA256 checked. Virtual Media
  through iDRAC 8 runs at ~1.3 MB/s — the install's extraction step takes
  ~20 min that way; a USB stick in the server takes one.

### 1 — BIOS and iDRAC

| Setting | Value | Why |
|---|---|---|
| Boot mode | UEFI | |
| AC Power Recovery | **Off** | after a power cut it waits for `W`; it is not on the UPS |
| System Memory Testing | Disabled | POST is the loud part |
| F1/F2 Prompt on Error | Disabled | a warning must never park it at a prompt |
| NIC boot protocols (PXE) | Disabled | |
| Slot Disablement → Slot 5 | **Disabled** | the Quadro P2200 stays in the chassis but invisible; TrueNAS has no driver for Pascal |
| Lifecycle Controller: Collect System Inventory on Restart | Disabled | the largest POST saving, ~1-2 min |
| Third-party PCIe fan response | Disabled | no fan uplift for a non-Dell card |
| H730P | HBA personality | TrueNAS sees the disks directly |

The last three are iDRAC settings, over SSH as iDRAC root:

```sh
racadm set LifecycleController.LCAttributes.CollectSystemInventoryOnRestart Disabled
racadm set System.ThermalSettings.ThirdPartyPCIFanResponse Disabled
```

iDRAC user `vaultwake`: **Operator**, IPMI over LAN on, enabled. Creating it
in-band from a running OS (`ipmitool user set …`) works; type each password
at its own prompt — pasting a block feeds the next line in as the password.

### 2 — Install

1. Installer → *Install/Upgrade* → select the two **INTEL SSDSC2KB960G8**
   disks by model. Device letters move between boots; never select by letter.
2. Admin `truenas_admin`. A forgotten password is reset from the console menu,
   option 4.
3. First login. **System → General → Localization → Timezone
   `Europe/Bucharest`** — the default is America/Los_Angeles, which would
   shift `W`, logs and snapshot names by ten hours.
4. System → Network: Global Configuration first (hostname `vault`, DNS and
   gateway `10.57.57.1`), then `eno4`: DHCP off, `10.57.57.250/24`. *Save*
   only stages it — **Test Changes**, reconnect on `.250` within 60 s,
   **Save Changes**.
5. Update profile: *Mission Critical*.
6. SSH is per user in 25.10: Credentials → Users → `truenas_admin` → tick
   **SSH Access** (the key field appears only then), paste the workstation's
   key. System → Services → SSH: running, start automatically, no password
   logins.

### 3 — Pool

1. **SMART long test on every pool disk first.** 25.10 has no SMART tests in
   the UI, and `midclt call disk.smart_test` returns without starting one:

   ```sh
   for d in $(lsblk -dno NAME,ROTA | awk '$2 == 1 {print $1}'); do sudo smartctl -t long /dev/$d; done
   ```

   ~70 min. A disk with a failed test, grown defects or uncorrected errors
   stays out.
2. Storage → Create Pool `vault`, encryption on, RAIDZ3, width 12, one vdev,
   nothing else. Disks from an old pool need its group ticked on page 1.
   **Download the key** and put it in the password manager.
3. If creation fails with **"no such pool or dataset"**: a udev race. The
   wizard repartitions, and some `/dev/disk/by-partuuid` links appear after
   ZFS has given up on them (`open error=2` in
   `/proc/spl/kstat/zfs/dbgmsg`). Zap the disks and reboot, then create again:

   ```sh
   for d in $(lsblk -dno NAME,ROTA | awk '$2 == 1 {print $1}'); do sudo sgdisk -Z /dev/$d; done
   ```

### 4 — Datasets, snapshots, SMB

| Dataset | Preset | Record size | Holds | Snapshots | Off-site |
|---|---|---|---|---|---|
| `backup` | Generic | 1M | `nas/` (pull of NAS `backups/`, `homes/`), `github/` | 30 daily + 12 monthly | yes |
| `files` | SMB | 1M | `Personal/ Job/ Clients/ Lab/` — the Drive layout | 30 daily | yes, except `Personal/Movies`, `Personal/VMs` |
| `system` | Generic | default | scripts, logs, config export, `secrets/` (0700) | 30 daily | yes, except `secrets/` |

One dataset per writer — the nightly run, you, the scripts — because
snapshots are per dataset. Everything finer is a folder.

Periodic snapshot tasks, all recursive, empty snapshots off, scheduled 13:30
as a backstop (the run triggers them anyway): three at 30 days, plus
`vault/backup` monthly on day 1, 12 months, schema `monthly-%Y-%m-%d_%H-%M`.

SMB: user `merox` with **only** SMB access. Share `files` (created by the SMB
preset): *Hosts Allow* `10.57.97.57` (the MacBook's DHCP reservation) and
`10.57.57.1` (everything arriving over Tailscale is NATed to pfSense);
Apple-style character encoding on, before anything is written. ACL: owner and
group `merox`, drop `builtin_users` (it would grant every future SMB user
modify), recursive.

### 5 — Credentials and the NAS

`/mnt/vault/system/secrets/`, root, 0600:

| File | What |
|---|---|
| `vault.env` | `W`, NAS and Oracle addresses, healthchecks URL, Telegram bot and chat — template [vault.env.example](vault.env.example) |
| `rsync-password` | DSM user `vault-pull` |
| `restic-password` | the repository password (the VPS has it in `/etc/restic/repo-password`) |
| `rest-password` | rest-server user `vault` |
| `pwenc_secret` | copied by every run; decrypts the passwords inside the config export |

On the NAS: DSM user `vault-pull`, not an administrator, **read-only** on
`backups` and `homes`, every application denied but rsync. File Services →
rsync: service on **and "Enable rsync account" on** — daemon mode refuses
ordinary DSM accounts (`@ERROR: account system disabled`); give `vault-pull`
an rsync account with the same password. Application Privileges → rsync:
`vault-pull` from `10.57.57.250` only. The rsync service brings a default
`NetBackup` share with it that cannot be deleted while rsync is on: keep it
empty, hidden, no access.

On Oracle: generate the `vault` password on the vault, hash it there with
bcrypt, append only the `user:hash` line to
`/srv/docker/rest-server/auth/.htpasswd` — check that file ends in a newline
first, or the entry merges into the line above.

### 6 — Scripts and schedules

Copy `scripts/*.sh` to `/mnt/vault/system/scripts/` (root, 0700) and
`config/*` to `/mnt/vault/system/config/`. Install restic from the release,
checking [restic.sha256](restic.sha256), to `/mnt/vault/system/bin/restic` —
TrueNAS ships 0.16.

| What | Where |
|---|---|
| Init script, POSTINIT, timeout 10: `vault-init.sh` | System → Advanced |
| Cron `10 13 * * *` root: `vault-nightly.sh` (for a vault kept on) | System → Advanced |
| Cron `0 16 * * *` root: `vault-gate.sh` (backstop) | System → Advanced |
| Alert service: Telegram, WARNING+, the only one (delete the default E-Mail and SNMP) | System → Alert Settings |
| Built-in scrub task | **disabled** — the run starts scrubs |
| healthchecks `vault-nightly`: cron `0 13 * * *`, Europe/Bucharest, grace 1 h | healthchecks.io |
| `/etc/cron.d/vault-wake` | pve-3, from [proxmox/pve-3/etc/cron.d](../proxmox/pve-3/etc/cron.d/vault-wake) with `W` filled in |

### 7 — Prove it

Shut down, wake from pve-3 with the cron line's own command, and watch:
boot, the run in `/mnt/vault/system/logs/nightly-<date>.log`, the Telegram
question, power-off. Then two unattended days.

---

## The nightly run

[vault-nightly.sh](scripts/vault-nightly.sh), started by the boot. A lock and
a "ran today" stamp make the boot and the 13:10 cron one run per day.

1. healthchecks `/start`
2. rsync pull of NAS `backups` and `homes` → `backup/nas/`, `--max-delete=500`.
   A deliberate mass move on the NAS trips it too (it did on 2026-10-03,
   after the photos were refiled by country): check the dry-run's deletions
   are moves, then `touch /mnt/vault/system/ALLOW-DELETES` — one run without
   the limit, and the file is gone again.
   Excluded: DSM indexes and recycle bins, every `.ssh/`, the `admin` home —
   unreadable to `vault-pull`, and an unreadable file makes rsync exit 23
3. `git clone --mirror` / `remote update` of [config/github-repos](config/github-repos)
4. TrueNAS config: `sqlite3 .backup` of the database, `pwenc_secret` to secrets
5. Snapshot tasks due today (the monthly one only on its day).
   `pool.snapshottask.run` is not a job — `midclt call -j` waits forever on it
6. restic backup → Oracle, host `vault`; cache on the pool
7. restic check; 5 % of the data read back on Sundays
8. 1st of the month: restore drill, `pfsense` and `oracle-vps` restored and
   hash-compared with what is live
9. Sundays: `pool.scrub.run vault 28` (so monthly). First Sunday: `smartctl
   -t long` on every rotational disk. Started by the run, not the clock: a
   task at a fixed minute raced the gate and could be powered off as it began
10. Done — only reaching this line counts as success. A run killed by a signal
    once reached its exit trap with status 0 and was reported as done

Whatever happens, [vault-gate.sh](scripts/vault-gate.sh) runs at the end:

- `HOLD` in `/mnt/vault/system` keeps it on. "Keep on" on Telegram writes it
  as `until-next-run` and the next run removes it; a `HOLD` made by hand stays
  until removed by hand.
- A resilver is always waited for. A scrub is paused and a SMART test aborted
  at `W` + 2 h.
- Then, every time, the question with two buttons. Silence means off. The
  bot is the homelab bot that Alertmanager and n8n send through; the gate is
  its only reader — a webhook on it would steal the button presses.

---

## Restores

Manual on purpose: the vault holds no write credential into the NAS. Wake it,
`touch /mnt/vault/system/HOLD`, remove it when done.

| Lost | From | How |
|---|---|---|
| A file | vault snapshot | `/mnt/vault/backup/nas/.zfs/snapshot/<name>/homes/…` → copy to the Mac → back through Drive |
| A Longhorn volume | Garage on the NAS | Longhorn UI → Backup → Restore; the vault is not involved |
| Garage's store | vault | rsync `backup/nas/backups/longhorn/` → NAS as the DSM admin, restart Garage, restore in Longhorn |
| The NAS | vault | new disks → DSM → shares per [synology/README.md](../synology/README.md) → rsync each folder back as admin |
| The NAS and the vault | Oracle | `restic restore` from any machine with the repository password |
| The vault's OS | anywhere | reinstall, import `vault` with the pool key, upload the config export, put `secrets/` back |

Write-back always uses a temporary credential — the DSM admin over SSH,
typed, never stored on the vault.

---

## Open

- 2FA on `truenas_admin` and *Allowed IP Addresses* for the UI — deferred by
  the owner on 2026-10-02.
- The three films for a NAS outage, into `files/Personal/Movies` by hand.
