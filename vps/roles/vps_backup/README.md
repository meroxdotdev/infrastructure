# vps_backup

**Canonical reference for the whole backup strategy** — the main README, DEPLOY.md
and DR.md link here instead of repeating the schedule.

Backup plumbing for the Oracle VPS. Two pieces, both cron-driven:

| Script | Cron | What it does |
|---|---|---|
| `backup-vps-extras.sh` | 01:30 | Tars small service state not covered by Ansible/git into `/srv/backups/`: Guacamole connections, Traefik `acme.json`, Pi-hole config (history/gravity DBs excluded), OpenClaw agent runtime (`.env` and logs excluded), agent dashboard state + secrets (`data/*.json`, `.env`). 7-day retention. |
| `backup-push-nas.sh` | 03:30 | Off-site sync to the Synology NAS: takes a consistent Garage metadata snapshot, then SSHes into the NAS which **pulls** `/srv/backups/` + Garage data/meta-snapshots from the read-only rsyncd modules on this VPS. |

Authentik/Joplin DB dumps land in the same `/srv/backups/` staging via their own
roles (`authentik_setup` / `joplin_setup`, 01:15 / 01:20) and ride along in the
03:30 sync.

## Why pull instead of push

Synology DSM ships a patched rsync that refuses server-mode over SSH unless the
DSM "rsync service" is enabled (it isn't, and enabling it needs UI/root). Plain
SSH and *client*-mode rsync work fine on the NAS, so the VPS triggers the NAS
over SSH and the NAS pulls from the rsyncd daemon this VPS already runs for
Synology HyperBackup (`/etc/rsyncd.conf`, managed by this role).

## Nightly backup traffic (both directions)

- **22:xx (evening)** — NAS HyperBackup pushes ~25GB to VPS `/backup/synology` (NAS's own off-site).
- **01:15 / 01:20** — Authentik / Joplin pg_dump → `/srv/backups/` (7-day retention).
- **01:30** — `backup-vps-extras.sh` → `/srv/backups/` (see table above).
- **02:00** — Longhorn (K8s cluster) backs up media/ARR config volumes to Garage S3 on the VPS (retain 3).
- **03:30** — this role: NAS pulls `/srv/backups` + Garage to `/volume1/Server/oracle-vps-backups/`.

`/backup/synology` is deliberately NOT in any backup module — syncing the NAS's
own backup back to the NAS would be circular.

## What Longhorn backs up (K8s side)

Only volumes opted in via PVC label `recurring-job-group.longhorn.io/media: enabled`:
`jellyfin`, `jellyseerr`, `prowlarr`, `qbittorrent`, `radarr`, `sonarr` (configs).
Deliberately NOT backed up: Prometheus/Loki/Grafana/Netdata history, alertmanager,
all `*-cache` volumes, Uptime-Kuma history — regenerable, were ~35GB of noise.

## Still manual (keep copies off this VPS)

`age.key`, `vps/.vault_pass`, `~/.openclaw/.env`, `/srv/docker/oracle-cloud/.env`.

## One-time manual provisioning (not managed by Ansible)

1. SSH keypair `/root/.ssh/nas_backup` on the VPS, public key in
   `admin@NAS:~/.ssh/authorized_keys`.
2. `/etc/rsyncd.secrets` on the VPS (`synology-backup:<password>`, mode 600) —
   shared with HyperBackup.
3. Password file on the NAS: `/var/services/homes/admin/.vps-rsync.pass`
   containing just the password, mode 600.

## Restore

- Dumps/tars: copy back from `NAS:/volume1/Server/oracle-vps-backups/srv-backups/`
  into `/srv/backups/` on the new VPS.
- Authentik/Joplin: `cd vps && make restore` (interactive, drops + re-imports from dump).
- Guacamole/Traefik/Pi-hole: untar `srv-backups/<service>/` over the deployed
  dirs/volumes, then restart the container.
- OpenClaw + dashboard: `agent/README.md`'s DR steps untar
  `srv-backups/openclaw/` and `srv-backups/dashboard/` automatically if found
  in `/srv/backups/` — restores agent memory, `openclaw.json`, dashboard
  `data/*.json` and `.env` in one shot.
- Garage: copy `garage/data` to the new VPS, restore newest dir from
  `garage/meta-snapshots/` as `meta/db.lmdb` per Garage docs
  (https://garagehq.deuxfleurs.fr/documentation/operations/recovering/), then
  start the container and let Longhorn re-discover its backups.
