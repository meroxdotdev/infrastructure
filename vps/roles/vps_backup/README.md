# vps_backup

Backups of the Oracle VPS's own services, and the landing spot for the
estate's off-site restic repository. Cron-driven; times are UTC, the VPS's
system timezone.

Where this fits in the whole estate: [docs/architecture.md](../../../docs/architecture.md)
and [docs/plan-nas-hot-r730-cold.md](../../../docs/plan-nas-hot-r730-cold.md).

## Nightly

| Script | Cron (UTC) | What it does |
|---|---|---|
| `nightly-backup.sh` | 23:45 | Runs the three below in order and pings healthchecks once. Stops at the first failure — the push has nothing to send if a producer died. |
| `backup-joplin.sh` | by the wrapper | Joplin DB dump into `/srv/backups/`. |
| `backup-vps-extras.sh` | by the wrapper | Tars service state not covered by Ansible/git into `/srv/backups/`: Guacamole connections, Traefik `acme.json`, Pi-hole config (history/gravity DBs excluded), Homepage config (kubeconfigs excluded), Portainer state. 7-day retention. |
| `backup-push.sh` | by the wrapper | Pushes `/srv/backups/` to the NAS, `backups/oracle-vps/`. |
| `restore-drill.sh` | monthly, 1st @ 04:00 | Imports the newest Authentik and Joplin dumps into throwaway containers and checks the schema has tables. Never touches live DBs. |

The Authentik dump (23:40, `authentik_setup` role) lands in the same
`/srv/backups/` and rides along in the push.

### The push

rsync over SSH to the NAS as DSM user `vps`: not an administrator, rsync and
SFTP only, write access to `backups/` only, 10 GB quota. Its key
(`/root/.ssh/vps-backup`, private half in the vault variable
`vault_oracle_vps_to_r730xd_ssh_key`) is accepted only from `10.57.57.1` —
the VPS reaches the LAN through the tailnet and pfSense NATs it. The tailnet
grant is `tag:vps-proxy → 10.57.57.201 tcp:22`. User setup:
[synology/README.md](../../../synology/README.md#users).

Two DSM details the script depends on, both in its header: the full
`/volume1/…` path, and no `-p/-o/-g`, so DSM's ACLs survive and the vault can
read what lands.

The NAS keeps the latest copy only. History is the vault's job.

**Until phase 7** the script also pushes to the R730xd, whose restic run is
still the off-site path. That second rsync, `vps_backup_r730xd_host`, and the
grant `tag:vps-proxy → 10.57.57.250 tcp:22` all go together then.

## Alerting

Two healthchecks: `vps-nightly-backup` (the wrapper, URL
`vault_hc_backup_push_url`) and the monthly drill
(`vault_hc_restore_drill_url`). The scripts inside the wrapper do not ping;
each exits non-zero, and that is the whole interface. Empty URLs are a no-op.

## The restic landing user

`restic-backup`: shell-less, chrooted, SFTP-only, home `/srv/restic-repo`. It
receives the estate's off-site restic repository — today from the R730xd,
after phase 7 from the vault. The public key is `vps_backup_restic_public_key`;
the private half never lives on this VPS. The repository is append-only
through `rest-server`, and retention runs here, where the data is trusted —
see [docs/architecture.md](../../../docs/architecture.md#nothing-can-delete-its-own-backups).

## Restore

`make dr-restore` runs these in order (`playbooks/dr-restore.yml`), after
`make setup` and the app stack exist on the fresh VPS:

1. `make restore-pull` — pulls the latest copy back from the NAS into
   `/srv/backups/`. An older copy comes from the vault's snapshots; if the NAS
   and the vault are both gone, from the `oracle-vps/` path in the restic
   repository on this VPS ([DR.md](../../../DR.md)).
2. `make restore-auto` — drops and re-imports Authentik and Joplin from their
   latest dumps (`make restore` asks per service).
3. `make restore-extras` — untars the newest archive of each extra service over
   its directory and restarts it. If the VPS got a new tailnet IP, it also
   repoints Pi-hole's `*.cloud.merox.dev` records.

## Kept by hand, off this VPS

`age.key`, `vps/.vault_pass` (also on the admin workstation, for running
Ansible against hosts at home), `/srv/docker/oracle-cloud/.env`. Homepage's
kubeconfigs are not backed up; after a cluster rebuild, copy a fresh
`talosctl kubeconfig` into both paths.
