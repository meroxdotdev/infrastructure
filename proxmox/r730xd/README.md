# proxmox/r730xd

**Canonical reference for R730xd-side backup infrastructure** — README.md and
DR.md link here instead of repeating the schedule.

R730xd (`pve`, `10.57.57.250`) is the hub of the homelab backup mesh: it's
both the primary Longhorn (K8s) backup target and the landing spot for its
own VM/pfSense backups, and (as of 2026-07-23) relays a curated, versioned
copy weekly to the Synology (now cold-storage only). Off-site to Oracle
Cloud is the one leg still not built — see "Downstream legs" below.

## The backup-orchestration LXC

Container 103 (`garage-r730xd`, `10.57.57.61` — static via a pfSense DHCP
reservation on MAC `bc:24:11:8b:b7:e9`, not a hand-set static IP) is a small
Debian 12 LXC (2 vCPU, 2GB RAM, unprivileged, `nesting=1`) whose only jobs
are: run Garage (below), and later host the Synology-relay and Oracle-restic
cron scripts. Provisioned via Ansible, not by hand:

```bash
cd vps
ansible-playbook -i inventories/production/hosts playbooks/garage-setup-r730xd.yml
```

Reuses `vps/roles/garage_setup` (same role as the VPS's own Garage instance)
with `garage_require_tailscale: false` and `garage_webui_enabled: false` —
this instance is LAN-only, no public domain, no Traefik. Both toggles default
`true` so the VPS's existing deployment is unaffected.

## Garage (Longhorn's backup target)

- S3 endpoint: `http://10.57.57.61:3900`, region `us-east-1`, bucket
  `longhorn` — same bucket/region names as the VPS's old instance, so
  `.taskfiles/longhorn/Taskfile.yaml`'s hardcoded `s3://longhorn@us-east-1/`
  string didn't need to change.
- Data lives on the `media` ZFS pool, **not** the LXC's own rootfs:
  `media/backups/longhorn-garage/{data,meta}`, bind-mounted into the LXC
  (owned by UID/GID 100000 on the host — the unprivileged container's root).
  This keeps the LXC itself stateless/reprovisionable and out of any vzdump
  job — only the ZFS-backed data matters, and that's exactly what the
  Synology/Oracle relays below need to touch anyway.
- Credentials: `docker exec garage /garage key info longhorn-key --show-secret`
  on the LXC. Consumed by Longhorn via
  `kubernetes/apps/storage/longhorn/app/minio-secret.sops.yaml`
  (`AWS_ENDPOINTS` points here).
- Cutover from the old VPS-hosted Garage instance: 2026-07-21. The old
  `longhorn` bucket on the VPS is left untouched as a rollback safety net for
  2+ weeks (see git history for the exact date) before its contents are
  removed.

## Source tree for downstream relays

```
/media/backups/
├── dump/                 vzdump — home-assistant (101) nightly 02:30. VM 100
│                         (windows11) and orphaned VM 106 backups removed
│                         2026-07-23 — windows11 doesn't need backup, and 106
│                         was a leftover from a VM that no longer exists.
├── pfsense/              config.xml.gz, nightly 03:00 (0700 root:root — deliberately locked down)
├── longhorn-garage/      Garage data+meta (Longhorn's live backup store)
├── synology-home/        NOT a pull anymore as of 2026-07-23 — this is now
│                         the live, writable documents location (former
│                         Synology Drive content), exposed via Filebrowser's
│                         WebDAV (/dav/documents/). It's the source, not a
│                         mirror, so it flows outward in the weekly push below.
├── immich-postgres/      pg_dump of Immich's Postgres, nightly 03:30, 30-day retention (see DR.md)
└── oracle-vps/           Nightly SSH-rsync push FROM the Oracle VPS (Authentik/
                          Joplin DB dumps, Guacamole/Traefik/Pi-hole/Homepage/
                          Portainer state) — see "Oracle VPS → R730xd" below.
                          R730xd is the landing point, not the source; this
                          directory only ever receives, the weekly push below
                          is what relays it onward.
```

## Media/photos/isos NFS exports (K8s storage, not backup)

Separate purpose from the backup tree above, but same host/pool — the
`media` ZFS pool (RAIDZ2, 6x600GB SAS) also serves the K8s cluster's live
media and photo storage, migrated off Synology 2026-07-22/23:

| ZFS dataset      | NFS export         | Consumed by                                                  |
| ----------------- | ------------------- | ------------------------------------------------------------- |
| `media/library`   | `/media/library` (rw)  | Jellyfin (ro), Sonarr/Radarr/qBittorrent (rw) — `NFS_SERVER` var |
| `media/photos`    | `/media/photos` (rw)   | Immich — `upload` subdir (its own writable library), `external` subdir (read-only import of the migrated Synology Photos content) |
| `media/isos`      | `/media/isos` (ro)     | Filebrowser only (browsing) |
| `media/backups`   | `/media/backups` (rw)  | Filebrowser (ro), Immich's pg_dump CronJob, the vzdump/rsync jobs above |

`/etc/exports` ACL is `10.57.57.0/24` for all four (covers all three K8s
node IPs). Jellyfin/Sonarr/Radarr/qBittorrent get their server IP from the
shared `NFS_SERVER` cluster-var (now `10.57.57.250`); Immich and Filebrowser
hardcode `10.57.57.250` directly since their mounts are R730xd-specific by
design, independent of wherever `NFS_SERVER` points during any future
migration.

`media/library` is a single unified dataset/export (not split per
Movies/Shows/Downloads) specifically so Sonarr/Radarr/qBittorrent's
hardlink-based instant import still works — splitting it would force
copy+delete instead (same filesystem/export required for `rename()`/hardlink
to work).

Movies/TV/Downloads are treated as replaceable "cattle" (re-downloadable) —
deliberately no second copy anywhere, unlike the backup tree above. Photos
are "pets" — the pre-migration Synology copy is kept as a safety net until
Immich is validated end-to-end (see
[docs/immich-post-restore.md](../../docs/immich-post-restore.md)).

### Footgun: nested ZFS datasets need `crossmnt`, and stale k8s node NFS caches don't self-heal

`media/backups` has child ZFS datasets nested inside it (`longhorn-garage`,
`synology-home`) that mount at their own paths under the parent dataset's
directory tree. **NFS does not expose nested mount points to clients by
default** — from a client's view they just look like permanently empty
directories, even though `ls` on `pve` itself shows real content. Fix: add
`crossmnt` to the parent export in `/etc/exports` (belt-and-suspenders: also
add explicit export lines for each nested dataset path). Applies to any
future nested-dataset-under-an-export setup on this pool, not just backups.

**The much nastier part**: fixing the export server-side is not enough by
itself. The Linux NFS client on a k8s node caches dentries/attributes for a
given server+export combo, and **new pod-level mounts on a node that already
had a stale (pre-fix) mount of that export can inherit the stale cached view
of specific nested paths** — confirmed by testing the identical k8s NFS
volume mount from a different, never-previously-mounted node
(`kubernetes-controlplane-2`), which worked immediately, while the
already-tainted node (`kubernetes-controlplane-1`) kept returning empty
listings for the nested paths no matter how many times the consuming pod
was deleted/recreated. `exportfs -ra` and even a full
`systemctl restart nfs-kernel-server` on `pve` did **not** clear this —
only a reboot of the affected k8s node did (`talosctl reboot -n <node-ip>`).
If a similar "works everywhere except this one node, and only for paths that
existed before an export change" symptom shows up again, suspect this same
cache-poisoning pattern before spending time on the export config again.

## Downstream legs

### R730xd → Synology (DONE, 2026-07-23)

Synology is now a **cold-storage-only** target — no live services (Photos,
Drive, Docker/HyperBackup all decommissioned), asleep except for a weekly
window.

- **DSM Power Schedule** (set directly in DSM, not scriptable — no root/API
  access to Synology was available): wake Sunday 02:50, shutdown Sunday
  04:30 (extended from the original 03:40 to give the now-retired
  HyperBackup relay room — safe to shrink back toward 03:40 since Synology
  only needs to receive pve's push now, not also relay onward). WoL
  confirmed enabled (Control Panel → Hardware & Power → General).
- **Push script**: `/root/scripts/weekly-push-to-synology.sh` on `pve`,
  cron `0 3 * * 0` (03:00 Sunday — 10 min after wake for margin, comfortably
  inside the 50-min window before shutdown).
- **Destination**: `admin@10.57.57.201:/volume1/NetBackup/<category>/`,
  reusing an existing empty share rather than creating a new one.
- **Versioned + deduplicated**: each category gets a dated snapshot dir
  (`<category>/YYYY-MM-DD/`) via `rsync --link-dest=../<previous-date>` —
  unchanged files are hardlinked from the prior snapshot (near-zero extra
  space), changed/new files cost real space. 21-day retention, pruned by
  **parsing the date from the folder name**, not filesystem mtime.

  ⚠️ **Footgun found and fixed**: the first version of this script pruned by
  `find -mtime`, which broke immediately — `rsync -a` preserves the *source*
  directory's own mtime onto the destination snapshot dir, which has nothing
  to do with when the snapshot was actually taken. This deleted a same-day
  snapshot right after creating it (silently — `rm` succeeded, no error).
  Confirmed via a from-scratch re-run after the fix; if the same "vanishes
  immediately after creation" symptom shows up in any other rsync-based
  retention script, suspect this exact class of bug first.

- **What's pushed**: `/media/photos` (Immich upload+external),
  `/media/backups/synology-home` (documents), `/media/backups/dump` (VM
  backups), `/media/backups/pfsense`, `/media/backups/longhorn-garage`,
  `/media/backups/immich-postgres`, `/media/backups/oracle-vps` (the Oracle
  VPS's own service backups — see below). Movies/TV/Downloads are
  deliberately excluded — replaceable "cattle", doesn't need a second copy.

### Oracle VPS → R730xd (DONE, 2026-07-23)

The Oracle VPS backs up its own service state (Authentik/Joplin DB dumps,
Guacamole/Traefik/Pi-hole/Homepage/Portainer tarballs) nightly at 03:30,
landing at `/media/backups/oracle-vps/srv-backups/` on pve. Deliberately
excludes the VPS's own local Garage instance (temporary rollback safety net
from the pre-cutover Longhorn setup, not the live backup target — that's the
LXC below). Full detail (script, cron, what's included) lives in
[vps/roles/vps_backup/README.md](../../vps/roles/vps_backup/README.md) —
canonical reference, don't duplicate here.

**Why this exists**: previously the VPS pushed straight to Synology
(`/volume1/Server/oracle-vps-backups/`), bypassing R730xd entirely — a
second, parallel backup path with its own logic, and one that never reached
Oracle's own offsite copy (below) since it wrote to a folder outside
`/media/backups`. Rerouting through R730xd means the VPS's own backups now
ride the same weekly Synology relay and the same nightly restic-to-Oracle
leg as everything else — one mesh, not two.

**How the VPS reaches pve**: plain SSH rsync push (no rsyncd daemon — that
indirection was only ever needed for Synology's patched rsync refusing
server-mode over SSH; R730xd is plain Debian, doesn't need it). The VPS's
key (`oracle-vps-to-r730xd`) is restricted in pve's `authorized_keys`:

```
restrict,command="rrsync /media/backups/oracle-vps",from="10.57.57.1" ssh-ed25519 AAAA... oracle-vps-to-r730xd
```

⚠️ **Footgun**: `from=` is `10.57.57.1` (pfSense's LAN address), **not** the
VPS's own Tailscale IP (`100.72.22.38`) — pfSense NATs Tailscale-routed
traffic before it reaches the LAN, so pve sees the connection as if it came
from pfSense itself. Using the VPS's real Tailscale IP here fails silently
with "not from a permitted host" (check `journalctl -u ssh` on pve, not
`/var/log/auth.log` — this Proxmox host uses `sshd-session` logging via
journald, no traditional auth.log file exists). If this key ever needs
recreating (new VPS, DR rebuild), regenerate on the VPS
(`ssh-keygen -t ed25519 -f /root/.ssh/oracle-vps-to-r730xd -N ""`), add the
public half to pve's `authorized_keys` with the line above, and update
`vault_oracle_vps_to_r730xd_ssh_key` in the vps Ansible vault to match.

### Synology → Oracle Cloud via HyperBackup (RETIRED, 2026-07-26)

Ran as DSM Hyper Backup (task type Rsync) from 2026-07-23 to 2026-07-26,
relaying `/volume1/NetBackup` onward to the VPS's `synology_backup` rsyncd
module. Retired once the restic leg below was extended to cover everything
this task relayed and proven with a real restore drill (not just a
successful push) — restoring from Hyper Backup's proprietary
chunked/versioned vault format needs a **working DSM instance** (real or
Virtual DSM), which was the whole reason to build a DSM-free alternative in
the first place. Keeping both once the DSM-free leg covered the same ground
was redundant, not extra safety — same content, same destination, two
tools. The `synology_backup` rsyncd module + `/etc/rsyncd.conf` on the VPS
were removed with it (see [vps/roles/vps_backup/README.md](../../vps/roles/vps_backup/README.md)).

Synology still gets the weekly push from R730xd below — that leg didn't
change, it just stopped also being asked to relay onward to Oracle.

### R730xd → Oracle Cloud, direct via restic (DONE, 2026-07-24; extended to full scope 2026-07-26)

DSM Hyper Backup's proprietary chunked/versioned vault format needs a
**working DSM instance** (real or Virtual DSM) to restore — not a plain
file copy. This leg exists so the offsite Oracle copy doesn't depend on
that: restic pushes straight from R730xd to the Oracle VPS over SFTP — open
repository format, restorable with just the `restic` binary and the repo
password, no vendor tool needed.

**Scope**: everything under `/media/backups/` plus `/media/photos` —
`oracle-vps/`, `immich-postgres/`, `pfsense/`, `longhorn-garage/`,
`synology-home/`, `/media/photos`. Originally scoped to just the first 4
("what do I need to rebuild fast") when Hyper Backup still covered the
rest; extended to the full set 2026-07-26 when Hyper Backup was retired, so
this became the sole offsite-to-Oracle leg for all of it. **Deliberately
excludes** `/media/backups/dump` (the Home Assistant VM's vzdump backup,
~14GB nightly) — Home Assistant is out of scope for this project entirely
(a VM the owner tinkers with, not something needing offsite DR), and
including it was pure wasted bandwidth/storage with no one asking for it.

**Destination**: a dedicated, shell-less, chrooted SFTP-only user
(`restic-backup`) on the Oracle VPS, provisioned by the `vps_backup`
Ansible role (see [vps/roles/vps_backup/README.md](../../vps/roles/vps_backup/README.md)).
The private half of the SSH keypair lives on R730xd only — not in this repo,
since pve isn't Ansible-managed.

**One-time setup on pve** (run once, by hand):

```bash
# 1. Install restic
apt update && apt install -y restic

# 2. SSH keypair already generated on the VPS side and its public half
#    deployed to restic-backup's authorized_keys. Get the private key from
#    whoever ran the Ansible role (or regenerate the pair — see "Recreating
#    this key" below) and place it:
install -m 600 /path/to/restic-r730xd-to-oracle /root/.ssh/restic-r730xd-to-oracle

# 3. SSH config alias (avoids fiddly -o sftp.command quoting)
cat >> /root/.ssh/config <<'EOF'

Host oracle-vps-restic
    HostName 100.72.22.38
    User restic-backup
    IdentityFile /root/.ssh/restic-r730xd-to-oracle
    StrictHostKeyChecking accept-new
    BatchMode yes
EOF
chmod 600 /root/.ssh/config

# 4. Repo password - generate your own, store it in your password manager
#    (Joplin, wherever age.key/.vault_pass live). Without this password the
#    repo is unrecoverable - treat it with the same care as age.key.
openssl rand -base64 32 > /root/.restic-oracle-password
chmod 600 /root/.restic-oracle-password

# 5. Init the repo (one-time)
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
export RESTIC_PASSWORD_FILE="/root/.restic-oracle-password"
restic init
```

**Nightly push script** (`/root/scripts/restic-push-oracle.sh` on pve, cron
`15 4 * * *` — after the ZFS snapshot below and clear of the Sunday
weekly-push window). Pings `restic-push-oracle` on healthchecks.io
(same account as everything else's alerting) on success, `/fail` on error:

```bash
#!/bin/bash
set -euo pipefail
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
export RESTIC_PASSWORD_FILE="/root/.restic-oracle-password"

HC_URL="https://hc-ping.com/..."  # healthchecks.io check "restic-push-oracle"
trap '[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL/fail" || true' ERR

restic backup /media/backups/oracle-vps /media/backups/immich-postgres \
  /media/backups/pfsense /media/backups/longhorn-garage \
  /media/backups/synology-home /media/photos --tag nightly
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
restic check

[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
```

**Restoring** (from any machine with `restic`, the repo password, and
network access to the VPS — no DSM, no Synology, nothing else needed):

```bash
export RESTIC_REPOSITORY="sftp:restic-backup@<vps-tailscale-ip>:/data"
export RESTIC_PASSWORD_FILE=/path/to/saved/password
restic snapshots
restic restore latest --target /tmp/restored
```

**Monthly restore drill** (`/root/scripts/restic-restore-drill.sh` on pve,
cron `0 5 1 * *` — day 1, clear of the nightly push): restores
`pfsense/` and `immich-postgres/` from the *live* repository to a throwaway
dir, compares content hashes against the current source, exit non-zero on
any mismatch. Proves the repo is actually restorable, not just that
`restic check` says its internals are consistent — same philosophy as
[vps-restore-drill](../../vps/roles/vps_backup/README.md#restore-drill-monthly),
separate script because the restic password and repo access live here, not
on the VPS. Pings `restic-restore-drill` on healthchecks.io.

**Recreating this key** (new R730xd, or key rotation): generate a new pair
on pve (`ssh-keygen -t ed25519 -f /root/.ssh/restic-r730xd-to-oracle -N ""`),
then update `vps_backup_restic_public_key` in
`vps/roles/vps_backup/defaults/main.yml` on the VPS side and re-run the
`vps_backup` role (`--tags backup`) to redeploy `authorized_keys`.

### ZFS snapshots on `media/backups` (DONE, 2026-07-24)

Both downstream legs above only protect against R730xd being *lost*, not
against something (a compromised VPS, a bad script, a fat-fingered `rm`)
*silently deleting or corrupting* what's already landed here — the VPS's
own nightly push uses `rsync --delete`, so a bad actor upstream mirrors
straight through unless caught before the next weekly Synology relay.
R730xd already has ZFS underneath (`media` pool, RAIDZ2), so a same-host,
zero-extra-tooling point-in-time undo window is effectively free.

**One-time cron on pve** (`/root/scripts/zfs-snapshot-backups.sh`, daily
`0 4 * * *` — before the restic push above, after the VPS's 03:30 push and
the 03:xx local jobs land):

```bash
#!/bin/bash
set -euo pipefail
DATASET="media/backups"

zfs snapshot -r "${DATASET}@daily-$(date +%F)"

# prune snapshots older than 14 days (dated-name based, not mtime - mtime on
# a ZFS snapshot reflects dataset state, not snapshot creation time)
CUTOFF=$(date -d "-14 days" +%s)
zfs list -H -o name -t snapshot -r "$DATASET" | grep "@daily-" | while read -r snap; do
  snap_date="${snap##*@daily-}"
  snap_epoch=$(date -d "$snap_date" +%s 2>/dev/null) || continue
  [ "$snap_epoch" -lt "$CUTOFF" ] && zfs destroy "$snap"
done
```

Recovering from a snapshot: `zfs list -t snapshot -r media/backups` to find
the date, then either `zfs rollback` (destructive, whole dataset) or mount
the snapshot's hidden `.zfs/snapshot/<name>/` directory under the affected
path and copy out just what's needed (non-destructive, preferred).

## Site-alive heartbeat (healthchecks.io, DONE 2026-07-30)

Every mechanism above only speaks up when *it* fails — none of them can
report a total home-site outage (power, WAN, or pve itself down), because
they'd be down right along with it. A dead-man's-switch pinged from pve
itself covers exactly that gap: healthchecks.io emails `hello@merox.dev` if
the ping goes missing for longer than the grace window, which by definition
only happens when pve can no longer reach the internet at all.

**Script** (`/root/scripts/heartbeat-ping.sh` on pve, cron `*/5 * * * *`):

```bash
#!/bin/bash
set -euo pipefail
curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/..."  # healthchecks.io check "homelab-heartbeat"
```

Check config: Period 5 minutes, Grace 10 minutes — tolerates one missed/slow
ping before alerting. Notification channel is plain Email (not Discord):
same independence from the primary Telegram alert channel, zero extra setup
since Email was already configured account-wide.

## Total-loss recovery

See ["R730xd / Garage total loss fallback"](../../DR.md#r730xd--garage-total-loss-fallback)
in DR.md.
