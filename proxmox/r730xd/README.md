# proxmox/r730xd

Canonical reference for R730xd-side backup infrastructure. `pve`
(`10.57.57.250`) is the hub of the backup mesh: Longhorn's backup target,
landing spot for VM/pfSense/VPS backups, weekly relay to Synology, nightly
restic push to Oracle.

Related: [REINSTALL.md](REINSTALL.md) (rebuild this host from bare metal) ·
[spindown-setup.md](spindown-setup.md) (SAS spin-down rebuild runbook) ·
[DR.md](../../DR.md) (total-loss recovery) ·
[vps_backup role](../../vps/roles/vps_backup/README.md) (VPS-side detail)

Host state that is not a clean install now lives in git:
[`scripts/`](scripts/) (the cron scripts), [`etc/crontab`](etc/crontab),
[`etc/exports`](etc/exports), [`etc/storage.cfg`](etc/storage.cfg),
[`etc/network-interfaces`](etc/network-interfaces). The host is the running
copy; these are the reviewable ones and the source for a reinstall.

## Nightly schedule

All jobs touching the `media` pool run in one compact window so the
spun-down SAS disks wake once per night. Times are EEST (pve local); K8s
and the Oracle VPS run UTC internally (shown in parens).

| Time (EEST) | Job | Runs on |
|---|---|---|
| 02:40 (23:40 UTC) | Authentik DB dump | VPS |
| 02:45 (23:45 UTC) | Joplin DB dump | VPS |
| 02:50 (23:50 UTC) | VPS extras tar (Guacamole/Traefik/Pi-hole/Homepage/Portainer) | VPS |
| 02:50 (23:50 UTC) | Longhorn → Garage backup (ARR/Jellyfin configs) | K8s |
| 02:55 | vzdump home-assistant (VM 101) | pve |
| 03:00 | pfSense config push (fixed, external) | → pve |
| 03:00 (00:00 UTC) | VPS → pve backup push | → pve |
| 03:01 | Garage meta copy (SSD → media) | pve |
| 03:02 (00:02 UTC) | Immich Postgres pg_dump | K8s |
| 03:05 | ZFS snapshot `media/backups` (14-day retention) | pve |
| 03:10 | restic push → Oracle | pve |
| 03:20 | SAS health check (SMART/defects/zpool counters, mails on anomaly only) | pve |
| weekly | Relay → Synology (cold storage) | pve |
| 05:00 1st/mo | restic restore drill | pve |
| 07:00 1st/mo (04:00 UTC) | Authentik/Joplin restore drill | VPS |

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
├── dump/              vzdump home-assistant, nightly 02:55
├── pfsense/           config.xml.gz, nightly 03:00 (mode 0700)
├── longhorn-garage/   Garage data (live) + meta (nightly copy from SSD)
├── synology-home/     LIVE documents (Filebrowser WebDAV) — source, not mirror
├── immich-postgres/   pg_dump, nightly 03:02, 30-day retention
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

Retired: Synology→Oracle HyperBackup (2026-07-26) — restoring its
proprietary vault needs a working DSM; the restic leg replaced it.

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

`/root/scripts/weekly-push-to-synology.sh`, weekly cron timed inside the
NAS wake window (exact schedule: `crontab -l` on pve), dest
`admin@10.57.57.201:/volume1/NetBackup/<category>/`. Pushes: photos
(stale copy), synology-home, dump, pfsense, longhorn-garage,
immich-postgres, oracle-vps, tools.

⚠️ Retention prunes by **date parsed from folder name**, never `find
-mtime` — `rsync -a` copies source mtimes, which once made the script
delete a snapshot the moment it was created.

### pve → Oracle (restic)

Open format — restorable anywhere with the `restic` binary + repo
password. Dest: chrooted SFTP-only user `restic-backup` on the VPS
(provisioned by the `vps_backup` role). Private key lives on pve only.

Scope: everything under `/media/backups/` + `/media/photos`, **except**
`dump/` (Home Assistant is out of DR scope, ~14GB/night of waste).

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

Nightly script `/root/scripts/restic-push-oracle.sh` (cron `10 3 * * *`,
pings healthchecks.io `restic-push-oracle`):

```bash
#!/bin/bash
set -euo pipefail
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
export RESTIC_PASSWORD_FILE="/root/.restic-oracle-password"
HC_URL="https://hc-ping.com/..."
trap '[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL/fail" || true' ERR
restic backup /media/backups/oracle-vps /media/backups/immich-postgres \
  /media/backups/pfsense /media/backups/longhorn-garage \
  /media/backups/synology-home /media/backups/tools /media/photos --tag nightly
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
restic check
[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
```

Restore from anywhere:

```bash
export RESTIC_REPOSITORY="sftp:restic-backup@<vps-tailscale-ip>:/data"
export RESTIC_PASSWORD_FILE=/path/to/password
restic snapshots && restic restore latest --target /tmp/restored
```

Monthly drill `/root/scripts/restic-restore-drill.sh` (cron `0 5 1 * *`):
restores pfsense + immich-postgres to a throwaway dir, hash-compares
against live source, pings `restic-restore-drill`.

Key rotation: new pair on pve → update `vps_backup_restic_public_key` in
`vps/roles/vps_backup/defaults/main.yml` → re-run role with `--tags backup`.

### ZFS snapshots

Protects against silent corruption/deletion propagating (the VPS push uses
`rsync --delete`). `/root/scripts/zfs-snapshot-backups.sh`, cron `5 3 * * *`:

```bash
#!/bin/bash
set -euo pipefail
DATASET="media/backups"
zfs snapshot -r "${DATASET}@daily-$(date +%F)"
# prune >14 days by date-in-name (snapshot mtime is meaningless)
CUTOFF=$(date -d "-14 days" +%s)
zfs list -H -o name -t snapshot -r "$DATASET" | grep "@daily-" | while read -r snap; do
  snap_date="${snap##*@daily-}"
  snap_epoch=$(date -d "$snap_date" +%s 2>/dev/null) || continue
  [ "$snap_epoch" -lt "$CUTOFF" ] && zfs destroy "$snap"
done
```

Recover: mount `.zfs/snapshot/<name>/` and copy out (non-destructive,
preferred) or `zfs rollback` (destructive, whole dataset).

## Site-alive heartbeat

Dead-man's switch for total site outage (power/WAN/pve down — nothing else
can report that). `/root/scripts/heartbeat-ping.sh`, cron `*/5 * * * *`,
pings healthchecks.io `homelab-heartbeat` (period 5min, grace 10min,
alerts via Email to hello@merox.dev — independent of the Telegram channel).
