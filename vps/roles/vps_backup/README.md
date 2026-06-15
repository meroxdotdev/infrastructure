# vps_backup

**Canonical reference for the whole backup strategy** — the main README, DEPLOY.md
and DR.md link here instead of repeating the schedule.

Backup plumbing for the Oracle VPS. Two pieces, both cron-driven:

| Script | Cron | What it does |
|---|---|---|
| `backup-vps-extras.sh` | 01:30 | Tars small service state not covered by Ansible/git into `/srv/backups/`: Guacamole connections, Traefik `acme.json`, Pi-hole config (history/gravity DBs excluded), OpenClaw agent runtime (`.env` and logs excluded), agent dashboard state + secrets (`data/*.json`, `.env`), Homepage config (`kubeconfig.yaml`/`kube.config` excluded), Portainer state. 7-day retention. |
| `backup-push-nas.sh` | 03:30 | Off-site sync to the Synology NAS: takes a consistent Garage metadata snapshot, then SSHes into the NAS which **pulls** `/srv/backups/` + Garage data/meta-snapshots from the read-only rsyncd modules on this VPS. |

Authentik/Joplin DB dumps land in the same `/srv/backups/` staging via the
`authentik_setup` role and this role's own Joplin backup cron (01:15 / 01:20)
and ride along in the 03:30 sync.

Two further scripts are DR-only (no cron) — see "Restore" below:
`restore-pull-from-nas.sh` and `restore-extras.sh`.

## Why pull instead of push

Synology DSM ships a patched rsync that refuses server-mode over SSH unless the
DSM "rsync service" is enabled (it isn't, and enabling it needs UI/root). Plain
SSH and *client*-mode rsync work fine on the NAS, so the VPS triggers the NAS
over SSH and the NAS pulls from the rsyncd daemon this VPS already runs for
Synology HyperBackup (`/etc/rsyncd.conf`, managed by this role).

`restore-pull-from-nas.sh` is the same indirection in reverse: the VPS SSHes
into the NAS, and the NAS *pushes* (still rsync client-mode on the NAS side)
into two additional **writable** modules on this VPS's rsyncd
(`vps_restore` → `/srv/backups`, `garage_restore` → Garage `data/` +
`meta/snapshots/`), restricted to the Tailscale subnet with the same
password auth as the read-only modules.

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

Also still manual: `/srv/docker/oracle-cloud/config/kubeconfig.yaml` and
`kube.config` (Homepage's Kubernetes widget) — excluded from the `homepage`
backup since they're regenerable. After a DR rebuild, recopy a `talosctl
kubeconfig` for the new cluster into both paths.

## One-time manual provisioning (not managed by Ansible)

1. SSH keypair for `/root/.ssh/nas_backup` — private half is in vault
   (`vault_nas_backup_ssh_key`, deployed by this role); public key must be in
   `admin@NAS:~/.ssh/authorized_keys`.
2. Password file on the NAS: `/var/services/homes/admin/.vps-rsync.pass`
   containing just the password, mode 600. Must match `vault_rsyncd_password`.

`/etc/rsyncd.secrets` on the VPS (`synology-backup:<password>`, mode 600) is
deployed by this role from `vault_rsyncd_password` — no manual step needed
on the VPS side anymore.

## Restore

`make dr-restore` runs the three steps below in order via
`playbooks/dr-restore.yml`. Run it after `make setup` (and `app-stack.yml`)
have deployed all containers on the fresh DR VPS.

- **Step 0**: `make restore-pull-nas` — pulls `srv-backups/` back into
  `/srv/backups/` and Garage `data/`/`meta-snapshots/` back into
  `/srv/docker/oracle-cloud/garage/` from the NAS's copy. Run this first on a
  fresh DR VPS; everything below reads from these local paths.
- Authentik/Joplin: `make restore-auto` — non-interactive (`restore-db.sh
  --yes all`), drops + re-imports each DB from its latest dump. `make restore`
  is the interactive equivalent (asks per service) for manual use outside DR.
- Guacamole/Traefik/Pi-hole/Homepage/Portainer/dashboard/OpenClaw:
  `make restore-extras` — non-interactive, untars the newest
  `srv-backups/<name>/` archive over each deployed dir/volume and
  stops/starts the affected container. Run after the app stack, Guacamole,
  Traefik and Pi-hole containers exist (i.e. after `make setup`). OpenClaw's
  archive is restored but its `openclaw-gateway` service is left for
  `agent/README.md`'s DR steps to start.
- Garage: copy `garage/data` to the new VPS, restore newest dir from
  `garage/meta-snapshots/` as `meta/db.lmdb` per Garage docs
  (https://garagehq.deuxfleurs.fr/documentation/operations/recovering/), then
  start the container and let Longhorn re-discover its backups.
