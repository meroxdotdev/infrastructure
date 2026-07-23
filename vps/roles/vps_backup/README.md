# vps_backup

**Canonical reference for the whole backup strategy** — the main README, DEPLOY.md
and DR.md link here instead of repeating the schedule.

Backup plumbing for the Oracle VPS. Two pieces, both cron-driven:

| Script | Cron | What it does |
|---|---|---|
| `backup-vps-extras.sh` | 01:30 | Tars small service state not covered by Ansible/git into `/srv/backups/`: Guacamole connections, Traefik `acme.json`, Pi-hole config (history/gravity DBs excluded), Homepage config (`kubeconfig.yaml`/`kube.config` excluded), Portainer state. 7-day retention. |
| `backup-push-r730xd.sh` | 03:30 | Off-site sync to R730xd (`pve`, `10.57.57.250`): **pushes** `/srv/backups/` straight to `/media/backups/oracle-vps/srv-backups/` on pve over plain SSH rsync. Deliberately excludes this VPS's own local Garage instance — see below. |

Authentik/Joplin DB dumps land in the same `/srv/backups/` staging via the
`authentik_setup` role and this role's own Joplin backup cron (01:15 / 01:20)
and ride along in the 03:30 sync.

One further script is DR-only (no cron) — see "Restore" below:
`restore-pull-from-r730xd.sh`.

## Why push, and why no daemon indirection

R730xd (`pve`) is plain Debian — no restrictions on rsync server-mode over
SSH, unlike Synology's DSM. So this leg is just a normal `rsync -e ssh` push,
authenticated by a dedicated SSH key. No rsyncd daemon, no password file, no
"SSH in and trigger a pull" indirection — that dance (still used for the
*Synology* HyperBackup destination, see below) was only ever needed to work
around DSM's patched rsync, and doesn't apply here.

The key (`/root/.ssh/oracle-vps-to-r730xd`) is restricted on the pve side via
`rrsync` (limits it to `/media/backups/oracle-vps` only) and `from=` (limits
it to the source IP pfSense presents when relaying Tailscale traffic onto the
LAN — **not** the VPS's own Tailscale IP; traffic arrives at pve looking like
it's from pfSense's LAN address, `10.57.57.1`, because pfSense NATs it).
pve isn't in this repo's Ansible inventory, so this authorized_keys line is
provisioned by hand — see
[proxmox/r730xd/README.md](../../../proxmox/r730xd/README.md#downstream-legs)
for the exact line and how to recreate it.

`/etc/rsyncd.conf` on this VPS still runs one module, `synology_backup` —
that one's unrelated to the VPS's own backups. It's the destination Synology's
own **HyperBackup** task pushes into (`/backup/synology`), completing the
loop: R730xd → Synology (weekly cold copy, includes this VPS's backups once
they land on pve — see below) → Oracle (HyperBackup, off-site). The
`vps_backups`/`garage_backup`/`vps_restore`/`garage_restore` modules that used
to exist alongside it are gone — they only existed for the old VPS↔Synology
direct-pull mechanism this role no longer uses.

**Deliberately not backed up**: this VPS's own local Garage instance
(`docker exec garage ...`, containers `garage`/`garage-webui`). It was
Longhorn's backup target before the 2026-07-21 cutover to R730xd's own
Garage LXC and is being kept only as a temporary rollback safety net for a
couple of weeks past that date — not live, not growing, and about to be
deleted outright. Backing it up here would mean relaying this VPS's own
soon-to-be-decommissioned data through R730xd → Synology → back to Oracle via
HyperBackup — pure waste. The *real*, current Garage backup target
(R730xd's own LXC) is already covered by the `longhorn-garage` category in
R730xd's own weekly push — see
[proxmox/r730xd/README.md](../../../proxmox/r730xd/README.md#garage-longhorns-backup-target).

## Nightly backup traffic

- **01:15 / 01:20** — Authentik / Joplin pg_dump → `/srv/backups/` (7-day retention).
- **01:30** — `backup-vps-extras.sh` → `/srv/backups/` (see table above).
- **02:00** — Longhorn (K8s cluster) backs up media/ARR config volumes to Garage S3 on the VPS (retain 3).
- **03:30** — this role: push `/srv/backups` + Garage snapshot to R730xd (`/media/backups/oracle-vps/`).

From there, R730xd's own weekly Sunday push relays a copy on to Synology
(cold storage), and Synology's own HyperBackup task relays it further to this
same VPS's `/backup/synology` module — completing the loop back to Oracle
without this role needing to know or care about that hop. See
[proxmox/r730xd/README.md](../../../proxmox/r730xd/README.md#downstream-legs)
for that side of the story.

## What Longhorn backs up (K8s side)

Only volumes opted in via PVC label `recurring-job-group.longhorn.io/media: enabled`:
`jellyfin`, `prowlarr`, `radarr`, `sonarr` (configs, ~3GB total actual size).
Deliberately NOT backed up: `jellyseerr`/`qbittorrent` (dropped 2026-07-21 —
session state and easily-reconfigured settings, not worth restoring),
Prometheus/Loki/Grafana/Netdata history, alertmanager, all `*-cache` volumes,
Uptime-Kuma history — regenerable, were ~35GB of noise.

## Still manual (keep copies off this VPS)

`age.key`, `vps/.vault_pass`, `/srv/docker/oracle-cloud/.env`.

Also still manual: `/srv/docker/oracle-cloud/config/kubeconfig.yaml` and
`kube.config` (Homepage's Kubernetes widget) — excluded from the `homepage`
backup since they're regenerable. After a DR rebuild, recopy a `talosctl
kubeconfig` for the new cluster into both paths.

## One-time manual provisioning (not managed by Ansible)

1. SSH keypair for `/root/.ssh/oracle-vps-to-r730xd` — private half is in
   vault (`vault_oracle_vps_to_r730xd_ssh_key`, deployed by this role);
   public key must be in `root@pve:~/.ssh/authorized_keys`, restricted via
   `rrsync` + `from=` (see proxmox/r730xd/README.md for the exact line).
2. `/etc/rsyncd.secrets` (`synology-backup:<password>`, mode 600) is deployed
   by this role from `vault_rsyncd_password` — only feeds the `synology_backup`
   module now, which the Synology-side HyperBackup task authenticates against
   (password set directly in the DSM task, matching this same vault value).

## Restore

`make dr-restore` runs the three steps below in order via
`playbooks/dr-restore.yml`. Run it after `make setup` (and `app-stack.yml`)
have deployed all containers on the fresh DR VPS.

- **Step 0**: `make restore-pull-r730xd` — pulls `srv-backups/` back into
  `/srv/backups/` from R730xd's copy at `/media/backups/oracle-vps/`. Run
  this first on a fresh DR VPS; everything below reads from
  `/srv/backups/`. If R730xd itself is also gone, pull instead from
  Synology's `/volume1/NetBackup/oracle-vps/<latest-date>/` (the weekly
  relay copy) or, failing that, Oracle's own HyperBackup copy — restore that
  first onto a reachable Synology (or any rsync-compatible target) and
  proceed from there.
- Authentik/Joplin: `make restore-auto` — non-interactive (`restore-db.sh
  --yes all`), drops + re-imports each DB from its latest dump. `make restore`
  is the interactive equivalent (asks per service) for manual use outside DR.
- Guacamole/Traefik/Pi-hole/Homepage/Portainer: `make restore-extras` —
  non-interactive, untars the newest `srv-backups/<name>/` archive over each
  deployed dir/volume and stops/starts the affected container. Run after the
  app stack, Guacamole, Traefik and Pi-hole containers exist (i.e. after
  `make setup`). Afterwards it also diffs `tailscale_expected_ip` (vars.yml)
  against the live `tailscale ip -4` and, if the DR VPS got a new tailnet IP,
  sed-repoints Pi-hole's `*.cloud.merox.dev` local DNS records
  (pihole.toml, custom.list, 02-custom.conf) to the new IP and restarts
  Pi-hole — see DEPLOY.md's Tailscale IP note for the one remaining manual
  step.

This VPS's own local Garage instance (the pre-2026-07-21 Longhorn backup
target, kept only as a temporary rollback safety net) is deliberately out of
scope here — it's not backed up (see "Deliberately not backed up" above) and
not part of this restore flow. Longhorn's actual backup target is R730xd's
own Garage LXC; if *that* needs recovering, see
[DR.md's "R730xd / Garage total loss fallback"](../../../DR.md#r730xd--garage-total-loss-fallback).
