# proxmox/r730xd

Canonical reference for R730xd-side backup infrastructure. `pve`
(`10.57.57.250`) is the hub of the backup mesh: Longhorn's backup target,
landing spot for VM/pfSense/VPS backups, weekly relay to Synology, nightly
restic push to Oracle.

Related: [REINSTALL.md](REINSTALL.md) (rebuild this host from bare metal) ·
[spindown-setup.md](spindown-setup.md) (SAS spin-down rebuild runbook) ·
[DR.md](../../DR.md) (total-loss recovery) ·
[vps_backup role](../../vps/roles/vps_backup/README.md) (VPS-side detail)

Host state that is not a clean install now lives in git — the host is the
running copy, these are the reviewable ones:

| In git | What |
|---|---|
| [`scripts/`](scripts/) | cron + forced-command scripts |
| [`etc/crontab`](etc/crontab) | the schedule |
| [`etc/exports`](etc/exports) | NFS, per-host ACLs |
| [`etc/storage.cfg`](etc/storage.cfg) | PVE storage |
| [`etc/network-interfaces`](etc/network-interfaces) | bridges |
| [`etc/authorized_keys`](etc/authorized_keys) | forced commands (pubkeys redacted) |
| [`etc/jobs.cfg`](etc/jobs.cfg) | PVE job scheduler — vzdump disabled here, it runs from cron |
| [`nextcloud/`](nextcloud/) | the Nextcloud VM: compose, firewall rules, runbook |

Neighbours: [pfSense](../../pfsense/REINSTALL.md) · [px-0](../px-0/REINSTALL.md)

## Nightly schedule

All jobs touching the `media` pool run in one compact window, so scheduled
work wakes the spun-down SAS disks once per night. Playback wakes them too,
whenever it happens — that is expected; what is not is the enforcer parking
them mid-stream, fixed 2026-08-16 (see
[spindown-setup.md](spindown-setup.md#3-spin-down-enforcer-stateless-replaces-hd-idle)).
**Everything schedulable runs on UTC**, since 2026-08-20. The Oracle VPS, the
K8s cluster and Nextcloud AIO all schedule in UTC and cannot be changed; while
pve ran on local time the two sets coincided in summer by accident and split
an hour apart every winter, waking the SAS pool twice a night. pve's crontab
now carries `CRON_TZ=UTC`, and `vzdump` moved out of the Proxmox job scheduler
into the same crontab so it moves with the rest.

UTC is the source of truth below; EEST is what it looks like in summer.

| UTC | (EEST) | Job | Runs on |
|---|---|---|---|
| 23:40 | 02:40 | Nextcloud borg → `nextcloud/` | VM 1000 |
| 23:40 | 02:40 | Authentik DB dump | VPS |
| 23:45 | 02:45 | Joplin DB dump | VPS |
| 23:50 | 02:50 | VPS extras tar (Guacamole/Traefik/Pi-hole/Homepage/Portainer) | VPS |
| 23:50 | 02:50 | Longhorn → Garage backup (ARR/Jellyfin configs) | K8s |
| 23:55 | 02:55 | vzdump home-assistant (VM 101) | pve |
| 00:00 | 03:00 | VPS → pve backup push | → pve |
| 00:01 | 03:01 | Garage meta copy (SSD → media) | pve |
| 00:02 | 03:02 | Immich Postgres pg_dump | K8s |
| 00:03 | 03:03 | etcd snapshot | pve |
| 00:05 | 03:05 | ZFS snapshot `media/backups` (14-day retention) | pve |
| 00:10 | 03:10 | restic push → Oracle | pve |
| 00:20 | 03:20 | SAS health check (SMART/defects/zpool counters, mails on anomaly only) | pve |
| 00:25 | 03:25 | spin-down drift check | pve |
| 00:40 | 03:40 | monthly `media` scrub, 1st | pve |
| 02:00 | 05:00 | restic restore drill, 1st | pve |
| 04:00 | 07:00 | Authentik/Joplin restore drill, 1st | VPS |

Two jobs stay on **local** time on purpose, and both are worse off in winter:

- **Weekly relay → Synology.** The NAS wake schedule is set in DSM, in the
  NAS's own local time, and does not follow pve's crontab. A UTC line would
  fire before the NAS wakes every winter Sunday, and the script has no
  heartbeat, so the failure would be silent. Its line sits above `CRON_TZ`.
- **pfSense config push, 03:00 local**, fixed on pfSense itself. In summer it
  lands 10 minutes before the restic push and inside the window. In winter it
  lands *after* restic has already run, so that night's firewall config
  reaches Oracle one night late, and it wakes the SAS pool separately.
  Deliberately not moved: the only time that works in both seasons is 02:00
  local, which would wake the disks 40 minutes early for the seven months the
  current setting is perfect. A rarely-changing firewall config arriving a day
  late is the cheaper failure.

The Synology is asleep except a short weekly wake window (DSM Power
Schedule + WoL, set by hand in DSM UI). Exact day/hours deliberately not
published — source of truth is `crontab -l` on pve and the DSM settings.

## Storage layout

`media` pool: 2× RAIDZ2-6 (12× 600GB SAS), spin-down via the stateless
enforcer script (see [spindown-setup.md](spindown-setup.md)).

| Dataset | NFS export | Consumers |
|---|---|---|
| `media/library` | rw | Jellyfin (ro), Sonarr/Radarr/qBittorrent (rw) via `NFS_SERVER` var |
| `media/photos` | rw | Filebrowser only (browsing the stale safety-net copy) — Immich itself moved to Longhorn/SSD PVCs 2026-08-06. Export was briefly removed then, which broke Filebrowser (found + fixed 2026-08-07); re-added, this time checked against all known consumers first |
| `media/isos` | ro | Filebrowser |
| `media/backups` | rw | Filebrowser (ro), Immich pg_dump CronJob, backup jobs |

- Exports ACL: **per host, not the subnet** (narrowed 2026-08-11 — it was
  `10.57.57.0/24`, which with `no_root_squash` gave every device on the LAN
  root on the backup tree). Allowed clients: `10.57.57.80/82/84` (Talos
  nodes — all pod mounts originate there) and `10.57.57.254` (px-0, mounts
  `/media/backups` as PVE storage `r730xd-backups`, the DR-test target).
  Adding a client means adding its IP to `/etc/exports`, not widening back
  to `/24`. Previous file kept as `/etc/exports.bak-2026-08-11`.
- Immich/Filebrowser hardcode `10.57.57.250`; the ARR stack uses the
  `NFS_SERVER` cluster-var.

⚠️ `no_root_squash` is still set on every export — a permitted client can
still act as root on the exported trees. Removing it is **not** a drop-in
change: kubelet applies `fsGroup` to in-tree `nfs` volumes, and every ARR
pod uses `fsGroupChangePolicy: OnRootMismatch`, so a squashed chown can
stop pods from starting. Do it one export at a time with a rollback, not
in bulk.
- `media/library` is one dataset on purpose: ARR hardlink imports need
  same-filesystem `rename()`.
- Movies/TV/Downloads = replaceable, no second copy anywhere. Photos =
  backed up (Longhorn PVCs + Garage).

⚠️ **Nested datasets under an export need `crossmnt`** — without it,
clients see empty dirs. And a k8s node that mounted the export *before*
the fix caches the broken view; only `talosctl reboot` of that node clears
it (`exportfs -ra` / nfs-kernel-server restart do not).

### Backup source tree

```
/media/backups/
├── dump/              vzdump home-assistant, nightly 23:55 UTC
├── nextcloud/         borg repo, nightly 23:40 UTC, written by the VM over a
│                      forced-command SSH key (borg-nextcloud account).
│                      See nextcloud/README.md.
├── pfsense/           config.xml.gz, nightly 03:00 local (mode 0700)
├── longhorn-garage/   Garage data (live) + meta (nightly copy from SSD)
├── synology-home/     LIVE documents (Filebrowser WebDAV) — source, not mirror.
│                      Superseded by Nextcloud 2026-08-20; kept as the rollback
│                      and dropped from both outbound legs so its 30 GB are not
│                      backed up twice. Delete once the parallel run is over.
├── immich-postgres/   pg_dump, nightly 00:02 UTC, 30-day retention
├── oracle-vps/        VPS service backups, pushed nightly (receive-only)
└── tools/             Vendor binaries needed to rebuild this host (storcli .deb).
                       Mirrored here on purpose: a reinstall must not depend on
                       a Broadcom download URL still resolving. In the backup
                       legs, so it survives total loss.
```

## Garage (Longhorn backup target, LXC 103)

- Debian LXC `garage-r730xd`, `10.57.57.61` (pfSense DHCP reservation, MAC
  `bc:24:11:8b:b7:e9`), 2 vCPU / 2GB, unprivileged, `nesting=1`.
- Provision: `ansible-playbook -i inventories/production/hosts
  playbooks/garage-setup-r730xd.yml` (reuses `garage_setup` role,
  `garage_require_tailscale=false`, `garage_webui_enabled=false`).
- S3: `http://10.57.57.61:3900`, region `us-east-1`, bucket `longhorn`.
  Credentials: `docker exec garage /garage key info longhorn-key
  --show-secret`; consumed via `minio-secret.sops.yaml` in the Longhorn app.
- **Data** on `media/backups/longhorn-garage/data` (bind mount mp0, host
  UID 100000). **Meta** on `rpool/garage-meta` — SSD, mp1 — because its
  constant LMDB/heartbeat writes kept waking the SAS pool
  ([spindown-setup.md](spindown-setup.md)). Nightly 03:01 cron copies meta
  back under `media/backups/longhorn-garage/meta/` so all downstream legs
  cover it.
- LXC itself is stateless — not in any vzdump job.

## Downstream legs

| Leg | When | Method |
|---|---|---|
| VPS → pve | nightly 03:00 | SSH rsync push, rrsync-restricted key |
| pve → Synology | weekly, in NAS wake window | rsync `--link-dest` versioned snapshots, 21-day retention |
| pve → Oracle | nightly 03:10 | restic over SFTP, verified + monthly drill |
| ZFS snapshots | nightly 03:05 | `media/backups@daily-*`, 14-day retention |
| pfSense → pve | nightly 03:00 | pfSense-side cron pushes `config.xml.gz` over a forced-command key |

Retired: Synology→Oracle HyperBackup (2026-07-26) — restoring its
proprietary vault needs a working DSM; the restic leg replaced it.

### pfSense → pve

- Push runs on the firewall:
  [`pfsense/scripts/backup-to-r730xd.sh`](../../pfsense/scripts/backup-to-r730xd.sh)
- pve pins the key to a receiver:
  [`scripts/pfsense-backup-receive.sh`](scripts/pfsense-backup-receive.sh)
  — does the `scp -t` **and** the 30-day prune
- Rebuild steps: [pfsense/REINSTALL.md](../../pfsense/REINSTALL.md)

⚠️ **One `authorized_keys` line per key.** Until 2026-08-11 the same
public key sat on two lines with different forced commands. SSH matches
the first and ignores the rest, so a plain `scp -t` line won and the prune
never ran — despite being documented here.

⚠️ The push script and its private key live in `/root` on pfSense, which
is **not** in `config.xml.gz`. A config restore brings back the cron entry
but not the script it calls.

### UPS-triggered shutdown

The UPS (CyberPower VP700ELCD) is on **pve's own USB**, monitored by **NUT**.
`upsmon` shuts this host down locally on low battery — no second machine, no
SSH hop, no forced-command key.

```bash
upsc cyberpower                 # full status
systemctl status nut-monitor    # the thing that actually pulls the trigger
```

Config: `/etc/nut/ups.conf` (driver), `/etc/nut/upsmon.conf` (MONITOR +
`SHUTDOWNCMD`), `/etc/nut/upsd.users` (generated password). Shutdown fires on
`LB`, which this UPS reports at `battery.runtime.low = 300` — five minutes of
runtime left, against a measured total of ~12 minutes at 35% load.

**Why NUT and not PowerPanel** — this is the load-bearing detail, do not
"simplify" it back. The R730xd is **EHCI-only**: `lspci` shows two Enhanced
Host Controllers and no xHCI at all, and every external port sits behind an
internal hub. This UPS is a *low-speed* (1.5 Mbps) HID device, so it reaches
the CPU through the hub's transaction translator, and there it re-enumerates
on a metronomic 8-seconds-up / 3-seconds-down cycle. Verified 2026-08-17:

- identical on both EHCI controllers (`00:1a.0` and `00:1d.0`)
- identical with the monitoring daemon running *and* stopped — 17 events in
  90 s with nothing at all holding `/dev/usb/hiddev0`
- **zero USB errors** in `dmesg`; a bad cable or port throws `-71`/`-110`,
  this throws nothing
- the same UPS and cable were stable on px-0, which has xHCI

`pwrstatd` talks to `/dev/usb/hiddev0` and cannot survive that churn: it
reported only `State: Normal` and never once read battery charge, runtime or
load — so `lowbatt-threshold` and `runtime-threshold` had nothing to fire on.
NUT's `usbhid-ups` goes through **libusb**, reconnects across each re-enumeration
and reads the full variable set. The device still flaps; it simply stopped
mattering.

`powerpanel` is installed but **masked/disabled**. Leave it that way — the two
fight over the same device.

⚠️ Do not move the UPS back to px-0. That was the old design and it made a
graceful shutdown of the machine holding all the data depend on a second host
being awake.

Snapshots of both config files are in [`etc/nut/`](etc/nut/). `upsd.users` is
**not** here — it holds a generated password. Reissue it on a rebuild and put
the same string in `upsmon.conf`'s `MONITOR` line, or `upsmon` logs
`ERR ACCESS-DENIED` and silently never fires:

```bash
pw=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
printf '[upsmon]\n    password = %s\n    upsmon master\n' "$pw" > /etc/nut/upsd.users
sed -i "s/REDACTED-SEE-upsd.users/$pw/" /etc/nut/upsmon.conf
chown root:nut /etc/nut/upsd.users /etc/nut/upsmon.conf
chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf
systemctl restart nut-server nut-monitor    # restart, not reload - upsd caches the users file
```

### VPS → pve

`authorized_keys` line on pve (restricted):

```
restrict,command="rrsync /media/backups/oracle-vps",from="10.57.57.1" ssh-ed25519 AAAA... oracle-vps-to-r730xd
```

⚠️ `from=` must be `10.57.57.1` (pfSense LAN) — pfSense NATs
Tailscale-routed traffic, so pve never sees the VPS's Tailscale IP. Fails
silently otherwise; debug via `journalctl -u ssh` (no auth.log on this
host). Key rotation: regenerate on VPS, update
`vault_oracle_vps_to_r730xd_ssh_key` in the vps Ansible vault.

### pve → Synology

[`scripts/weekly-push-to-synology.sh`](scripts/weekly-push-to-synology.sh),
weekly, timed inside the NAS wake window. Schedule is redacted from
[`etc/crontab`](etc/crontab) — it reveals the wake window; real line is in
`/root/PRIVATE-NOTES.md`.

- Dest: `admin@10.57.57.201:/volume1/NetBackup/<category>/`
- Categories: photos (stale copy), synology-home, dump, pfsense,
  longhorn-garage, immich-postgres, oracle-vps, tools
- Versioned via `rsync --link-dest`, 21-day retention

⚠️ Retention prunes by **date parsed from the folder name**, never `find
-mtime` — `rsync -a` copies source mtimes, which once made the script
delete a snapshot the moment it was created.

⚠️ This is the only leg with **no healthcheck ping**. A silent failure is
invisible; check the log date if in doubt.

### pve → Oracle (restic)

Open format — restorable anywhere with the `restic` binary + repo
password. Dest: chrooted SFTP-only user `restic-backup` on the VPS
(provisioned by the `vps_backup` role). Private key lives on pve only.

Scope: everything under `/media/backups/`, plus `/media/photos` and
`/root`. Two exclusions, both deliberate:

- `dump/` — Home Assistant is out of DR scope, ~14 GB/night of waste.
- `synology-home/` — dropped 2026-08-20. Its contents now live in Nextcloud
  and reach Oracle through `nextcloud/`; pushing both would send the same
  30 GB twice. The directory stays on pve as the migration rollback.

`/root` was added 2026-08-11. Without it the cron scripts, `/root/.ssh`,
`PRIVATE-NOTES.md` and the restic password file existed on exactly one
disk, the one being backed up.

One-time setup on pve:

```bash
apt install -y restic
install -m 600 /path/to/restic-r730xd-to-oracle /root/.ssh/restic-r730xd-to-oracle
cat >> /root/.ssh/config <<'EOF'

Host oracle-vps-restic
    HostName 100.72.22.38
    User restic-backup
    IdentityFile /root/.ssh/restic-r730xd-to-oracle
    StrictHostKeyChecking accept-new
    BatchMode yes
EOF
chmod 600 /root/.ssh/config
openssl rand -base64 32 > /root/.restic-oracle-password   # save in password manager!
chmod 600 /root/.restic-oracle-password
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
export RESTIC_PASSWORD_FILE="/root/.restic-oracle-password"
restic init
```

Nightly: [`scripts/restic-push-oracle.sh`](scripts/restic-push-oracle.sh),
cron `10 3 * * *`. Retention `--keep-daily 7 --keep-weekly 4
--keep-monthly 3`, then `restic check`. Pings healthchecks.io.

Restore from anywhere:

```bash
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"   # ~/.ssh/config alias on pve
export RESTIC_PASSWORD_FILE=/path/to/password             # password manager
restic snapshots && restic restore latest --target /tmp/restored
```

Off-host, the alias doesn't exist — use `sftp:restic-backup@<vps-ip>:/data`
with the key from `/root/.ssh/`.

Monthly drill: [`scripts/restic-restore-drill.sh`](scripts/restic-restore-drill.sh),
cron `0 5 1 * *`. Restores pfsense + immich-postgres to a throwaway dir,
hash-compares against live source, pings healthchecks.io.

⚠️ The drill runs **on pve**, where the password file is present. It
proves the data is good; it cannot prove you can still open the repo
without pve.

Key rotation: new pair on pve → update `vps_backup_restic_public_key` in
`vps/roles/vps_backup/defaults/main.yml` → re-run role with `--tags backup`.

### ZFS snapshots

Protects against silent corruption/deletion propagating — the VPS push
uses `rsync --delete`.

[`scripts/zfs-snapshot-backups.sh`](scripts/zfs-snapshot-backups.sh), cron
`5 3 * * *`, `media/backups@daily-*`, 14-day retention.

Recover:

- **Non-destructive (preferred)** — mount `.zfs/snapshot/<name>/`, copy out.
- **Destructive** — `zfs rollback`, rolls back the whole dataset.

⚠️ Pruning parses the date **from the snapshot name**, never `find -mtime`.
Snapshot mtime is meaningless here.

## Site-alive heartbeat

Dead-man's switch for total site outage (power/WAN/pve down — nothing else
can report that). `/root/scripts/heartbeat-ping.sh`, cron `*/5 * * * *`,
pings healthchecks.io `homelab-heartbeat` (period 5min, grace 10min,
alerts via Email to hello@merox.dev — independent of the Telegram channel).
