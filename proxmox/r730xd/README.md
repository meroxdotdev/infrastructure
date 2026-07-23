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
└── immich-postgres/      pg_dump of Immich's Postgres, nightly 03:30, 30-day retention (see DR.md)
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
  03:40. WoL confirmed enabled (Control Panel → Hardware & Power → General).
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
  backups), `/media/backups/pfsense`, `/media/backups/longhorn-garage`.
  Movies/TV/Downloads are deliberately excluded — replaceable "cattle",
  doesn't need a second copy.

### Synology → Oracle Cloud (NOT built yet)

This is the actual remaining gap. Synology only becomes safe to treat as
disposable once this leg exists — right now, if the R730xd is lost between
Sunday backup windows, Synology has a copy, but if *both* are lost, there's
still no offsite copy. Plan (per the user, 2026-07-23): once R730xd→Synology
is proven stable, build an encrypted restic push from Synology to a new
Oracle Garage bucket, covering the same weekly snapshot content — this
finally completes Phase 3 of the original backup-restructure plan. Not
started as of this writing.

## Total-loss recovery

See ["R730xd / Garage total loss fallback"](../../DR.md#r730xd--garage-total-loss-fallback)
in DR.md.
