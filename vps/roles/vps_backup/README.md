# vps_backup

**Canonical reference for the whole backup strategy** — the main README, DEPLOY.md
and DR.md link here instead of repeating the schedule.

Backup plumbing for the Oracle VPS. Two pieces, both cron-driven:

All times below are UTC (this VPS's system timezone) — pve-2/R730xd runs
EEST (UTC+3), so these are timed to land there right around pve-2's own
03:00 EEST window (pfSense's fixed nightly push), keeping the SAS media
pool's spin-down to a single nightly wake instead of scattering across
several hours. See [proxmox/pve-2/README.md](../../../proxmox/pve-2/README.md)
for the pve-2 side of this alignment.

| Script | Cron (UTC) | What it does |
|---|---|---|
| `nightly-backup.sh` | 23:45 | Runs the three below in order and pings once. Stops at the first failure — the push has nothing to send if a producer died. |
| `backup-joplin.sh` | by the wrapper |  Joplin DB dump into `/srv/backups/`. |
| `backup-vps-extras.sh` | by the wrapper | Tars small service state not covered by Ansible/git into `/srv/backups/`: Guacamole connections, Traefik `acme.json`, Pi-hole config (history/gravity DBs excluded), Homepage config (`kubeconfig.yaml`/`kube.config` excluded), Portainer state. 7-day retention. |
| `backup-push-r730xd.sh` | by the wrapper | Off-site sync to R730xd (`pve-2`, `10.57.57.250`): **pushes** `/srv/backups/` straight to `/media/backups/oracle-vps/srv-backups/` on pve-2 over plain SSH rsync — lands ~03:00 EEST. Deliberately excludes this VPS's own local Garage instance — see below. |
| `restore-drill.sh` | monthly, 1st @ 04:00 | Proves the latest Authentik/Joplin dumps actually restore — imports each into a throwaway `--rm` postgres container, checks the schema has tables, tears down. Never touches live DBs. See "Restore drill" below. |

Authentik/Joplin DB dumps land in the same `/srv/backups/` staging via the
`authentik_setup` role and this role's own Joplin backup cron (23:40 / 23:45
UTC) and ride along in the 00:00 sync.

One further script is DR-only (no cron) — see "Restore" below:
`restore-pull-from-r730xd.sh`.

## Why push, and why no daemon indirection

R730xd (`pve-2`) is plain Debian — no restrictions on rsync server-mode over
SSH, unlike Synology's DSM. So this leg is just a normal `rsync -e ssh` push,
authenticated by a dedicated SSH key. No rsyncd daemon, no password file, no
"SSH in and trigger a pull" indirection — that dance (formerly used for the
now-retired *Synology* HyperBackup destination, see below) was only ever
needed to work around DSM's patched rsync, and doesn't apply here.

The key (`/root/.ssh/oracle-vps-to-r730xd`) is restricted on the pve-2 side via
`rrsync` (limits it to `/media/backups/oracle-vps` only) and `from=` (limits
it to the source IP pfSense presents when relaying Tailscale traffic onto the
LAN — **not** the VPS's own Tailscale IP; traffic arrives at pve-2 looking like
it's from pfSense's LAN address, `10.57.57.1`, because pfSense NATs it).
pve-2 isn't in this repo's Ansible inventory, so this authorized_keys line is
provisioned by hand — see
[proxmox/pve-2/README.md](../../../proxmox/pve-2/README.md#downstream-legs)
for the exact line and how to recreate it.

`/etc/rsyncd.conf` on this VPS is gone entirely as of 2026-07-26 — it used
to run one module, `synology_backup`, which was the destination Synology's
own HyperBackup task pushed into. That leg is retired (see
[proxmox/pve-2/README.md](../../../proxmox/pve-2/README.md#downstream-legs));
the offsite-to-Oracle job it did is now covered by R730xd's own
`restic-push-oracle.sh` instead. The `vps_backups`/`garage_backup`/
`vps_restore`/`garage_restore` modules that used to exist alongside
`synology_backup` were already gone before that — they only existed for an
even older VPS↔Synology direct-pull mechanism this role stopped using
2026-07-23.

**Deliberately not backed up**: this VPS's own local Garage instance
(`docker exec garage ...`, containers `garage`/`garage-webui`). It was
Longhorn's backup target before the 2026-07-21 cutover to R730xd's own
Garage LXC and was kept only as a temporary rollback safety net for a
couple of weeks past that date. The *real*, current Garage backup target
(R730xd's own LXC) is already covered by the `longhorn-garage` category in
R730xd's own weekly Synology push and nightly Oracle restic push — see
[proxmox/pve-2/README.md](../../../proxmox/pve-2/README.md#garage-longhorns-backup-target).

## Nightly backup traffic

All UTC. K8s cluster nodes also run UTC; pve-2/R730xd runs EEST (UTC+3) —
add 3h for pve-side local times.

- **23:40** — Authentik pg_dump → `/srv/backups/` (7-day retention, `authentik_setup` role).
- **23:45** — `nightly-backup.sh`: Joplin dump, extras tar, then the push to
  R730xd (`/media/backups/oracle-vps/`) — lands ~03:00 EEST.
- **23:50** — Longhorn (K8s cluster) backs up media/ARR config volumes to Garage S3 on R730xd (retain 3).

From there, R730xd's own weekly push relays a copy on to Synology
(cold storage, fast local-ish recovery), and — independently, nightly —
R730xd pushes the same data straight to Oracle via `restic`, without this
role needing to know or care about either hop. See
[proxmox/pve-2/README.md](../../../proxmox/pve-2/README.md#downstream-legs)
for that side of the story.

## What Longhorn backs up (K8s side)

Only volumes opted in via PVC label `recurring-job-group.longhorn.io/media: enabled`:
`jellyfin`, `jellyseerr`, `prowlarr`, `qbittorrent`, `radarr`, `sonarr`, `n8n`,
and Immich's three (`immich-postgres`, `immich-library-ssd`,
`immich-external-library-ssd`) — 10 PVCs total.

`jellyseerr`/`qbittorrent` were dropped from this list 2026-07-21 (session
state, not worth restoring) and re-added 2026-08-15 after that turned out to
delete live prod data, not just skip a DR restore — see
[`docs/dr-known-issues.md`](../../../docs/dr-known-issues.md) row on
`jellyseerr`/`qbittorrent` static PVs for the full incident. DR's
`restore-all-volumes` task still only restores 6 of these 10 by name
(`jellyfin`/`prowlarr`/`radarr`/`sonarr`/`immich-postgres`/`n8n`) — the same
doc's "Open" section covers that gap.

Deliberately NOT backed up: Prometheus/Loki/Grafana/Netdata history,
alertmanager, all `*-cache` volumes — regenerable, were ~35GB of noise.

## Restore drill (monthly)

A backup that's never restored is unverified — `restore-drill.sh` closes
that gap for the two DB dumps that matter most. Monthly (1st @ 04:00, clear
of the nightly 01:xx-03:xx window), it finds the newest Authentik and
Joplin dumps, imports each into a throwaway `postgres:16-alpine` /
`postgres:15` container (`docker run --rm`, no host port, anonymous volume
cleaned up automatically), checks `information_schema.tables` has rows,
then stops the container. A bad dump (corrupt gzip, broken SQL, empty
export) surfaces here within a month instead of silently during a real DR.
Pings healthchecks.io on success/`/fail` if `vault_hc_restore_drill_url` is
set. Logs: `/var/log/restore-drill.log`.

## Alerting (healthchecks.io)

Two checks, not four. `nightly-backup.sh` runs the Joplin dump, the extras
tar and the push to the R730xd as one 15-minute sequence and pings once —
they fail as a unit and are investigated as a unit, so a check per step was
three places to look for one answer. The three scripts themselves no longer
ping: each exits non-zero, and that is the whole interface. `restore-drill.sh`
keeps its own because it runs monthly, not nightly.

Same account as the K8s Watchdog heartbeat (see `alertmanagerconfig.yaml`),
no second monitoring stack. URLs come from `vault_hc_backup_push_url` (the
check renamed `vps-nightly-backup`) and `vault_hc_restore_drill_url`. Empty
is a no-op, so this is safe to deploy before the checks exist. Then:

```bash
cd vps
ansible-vault edit inventories/production/group_vars/all/vault.yml --vault-password-file .vault_pass
# add: vault_hc_backup_extras_url, vault_hc_backup_joplin_url,
#      vault_hc_backup_push_url, vault_hc_restore_drill_url
ansible-playbook -i inventories/production/hosts playbooks/site.yml --tags backup --vault-password-file .vault_pass
```

The Immich Postgres CronJob (K8s side) has the same pattern — see
`kubernetes/apps/default/immich/app/cronjob-postgres-backup.yaml`, URL in
`immich-postgres-secret`'s `hc_ping_url` key (sops).

## restic-backup user (SFTP landing for R730xd → Oracle, DSM-independent)

A dedicated, shell-less, chrooted SFTP-only system user
(`restic-backup`, home `/srv/restic-repo`, writable subdir
`/srv/restic-repo/data`) — the destination for R730xd's own restic push,
which exists so the Oracle offsite copy of the *critical* backup data
(VPS service backups, Immich Postgres dumps, R730xd's own VM/pfSense
backups) doesn't require a working Synology DSM instance to restore. sshd
is configured via `/etc/ssh/sshd_config.d/restic-backup.conf` (`Match User
restic-backup` → `ChrootDirectory` + `ForceCommand internal-sftp`, no
forwarding, no PTY, no password auth). The public key is a plain var
(`vps_backup_restic_public_key`, not secret); the matching private key
lives on R730xd only — see
[proxmox/pve-2/README.md](../../../proxmox/pve-2/README.md#r730xd--oracle-cloud-direct-via-restic-done-2026-07-24)
for the R730xd-side setup and restore instructions.

## Still manual (keep copies off this VPS)

`age.key`, `vps/.vault_pass`, `/srv/docker/oracle-cloud/.env`.

Also still manual: `/srv/docker/oracle-cloud/config/kubeconfig.yaml` and
`kube.config` (Homepage's Kubernetes widget) — excluded from the `homepage`
backup since they're regenerable. After a DR rebuild, recopy a `talosctl
kubeconfig` for the new cluster into both paths.

## One-time manual provisioning (not managed by Ansible)

1. SSH keypair for `/root/.ssh/oracle-vps-to-r730xd` — private half is in
   vault (`vault_oracle_vps_to_r730xd_ssh_key`, deployed by this role);
   public key must be in `root@pve-2:~/.ssh/authorized_keys`, restricted via
   `rrsync` + `from=` (see proxmox/pve-2/README.md for the exact line).

> **Synology HyperBackup retired 2026-07-26.** The rsyncd daemon/module
> (`synology_backup`) that existed solely as its destination is gone too —
> see [proxmox/pve-2/README.md](../../../proxmox/pve-2/README.md#downstream-legs)
> for what replaced it (R730xd's own `restic-push-oracle.sh`, extended to
> cover everything HyperBackup used to relay, proven with a real restore
> drill before the cutover, not just a successful push).

## Restore

`make dr-restore` runs the three steps below in order via
`playbooks/dr-restore.yml`. Run it after `make setup` (and `app-stack.yml`)
have deployed all containers on the fresh DR VPS.

- **Step 0**: `make restore-pull-r730xd` — pulls `srv-backups/` back into
  `/srv/backups/` from R730xd's copy at `/media/backups/oracle-vps/`. Run
  this first on a fresh DR VPS; everything below reads from
  `/srv/backups/`. If R730xd itself is also gone, restore instead from the
  `oracle-vps/` path inside R730xd's own restic repository (this same VPS,
  `/srv/restic-repo` — see [DR.md](../../../DR.md#r730xd--garage-total-loss-fallback)),
  or from Synology's `/volume1/NetBackup/oracle-vps/<latest-date>/` (the
  weekly relay copy, still running for fast local-ish recovery even though
  it no longer also relays onward to Oracle via HyperBackup).
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
