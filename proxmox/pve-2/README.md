# proxmox/pve-2

Canonical reference for R730xd-side backup infrastructure. `pve-2`
(`10.57.57.250`) is the hub of the backup mesh: Longhorn's backup target,
landing spot for VM/pfSense/VPS backups, weekly relay to Synology, nightly
restic push to Oracle.

It also runs `kubernetes-2` (VM 811) since 2026-09-04, one of the cluster's
three control planes, and the Nextcloud VM. Neither is documented here — see
[../../talos/THREE-NODE.md](../../talos/THREE-NODE.md) and
[nextcloud/README.md](nextcloud/README.md). This page stays about backups.

Related: [REINSTALL.md](REINSTALL.md) (rebuild this host from bare metal) ·
[spindown-setup.md](spindown-setup.md) (SAS spin-down rebuild runbook) ·
[known-issues.md](known-issues.md) (forensic record — UPS, fan noise) ·
[DR.md](../../DR.md) (total-loss recovery) ·
[vps_backup role](../../vps/roles/vps_backup/README.md) (VPS-side detail)

Host state that is not a clean install now lives in git — the host is the
running copy, these are the reviewable ones:

| In git | What |
|---|---|
| [`scripts/`](scripts/) | cron + forced-command scripts |
| [`etc/crontab`](etc/crontab) | the schedule |
| [`reinstall.sh`](reinstall.sh) | rebuilds this host after a Proxmox install — packages, storage, exports, ZFS props, cron, spin-down, borg receiver |
| [`etc/exports`](etc/exports) | NFS, per-host ACLs |
| [`etc/storage.cfg`](etc/storage.cfg) | PVE storage |
| [`etc/network-interfaces`](etc/network-interfaces) | bridges |
| [`etc/authorized_keys`](etc/authorized_keys) | forced commands (pubkeys redacted) |
| [`etc/jobs.cfg`](etc/jobs.cfg) | PVE job scheduler — no vzdump jobs; nothing on this host is dumped |
| [`etc/fan-control.service`](etc/fan-control.service) | runs [`scripts/fan-control.sh`](scripts/fan-control.sh) — the chassis fans |
| [`nextcloud/`](nextcloud/) | the Nextcloud VM: compose, firewall rules, runbook |

Neighbours: [pfSense](../../pfsense/REINSTALL.md)

## Nightly schedule

All jobs touching the `media` pool run in one compact window, so scheduled
work wakes the spun-down SAS disks once per night. Playback wakes them too,
whenever it happens — that is expected; what is not is the enforcer parking
them mid-stream, fixed 2026-08-16 (see
[spindown-setup.md](spindown-setup.md#3-spin-down-enforcer-stateless-replaces-hd-idle)).
Times below are **local** (pve-2, EEST in summer). The Oracle VPS, the K8s
cluster and Nextcloud AIO all schedule in UTC and cannot be changed; pve-2's cron
runs on local time. In summer the two sets interleave into one tight window,
which is the point — everything touching the spun-down SAS pool should wake the
disks once, together.

| Time | Job | Runs on |
|---|---|---|
| 02:40 (23:40 UTC) | Nextcloud borg → `nextcloud/` | VM 1000 |
| 02:40 (23:40 UTC) | Authentik DB dump | VPS |
| 02:45 (23:45 UTC) | Joplin DB dump | VPS |
| 02:50 (23:50 UTC) | VPS extras tar (Guacamole/Traefik/Pi-hole/Homepage/Portainer) | VPS |
| 02:50 (23:50 UTC) | Longhorn → Garage backup (ARR/Jellyfin configs, Immich library) | K8s |
| 03:00 | pfSense config push (fixed, external) | → pve-2 |
| 03:00 (00:00 UTC) | VPS → pve-2 backup push | → pve-2 |
| 03:01 | Garage meta copy (SSD → media) | pve-2 |
| 03:02 (00:02 UTC) | Immich Postgres pg_dump | K8s |
| 03:03 | etcd snapshot | pve-2 |
| 03:05 | ZFS snapshot `media/backups` (14-day retention) | pve-2 |
| 03:10 | restic push → Oracle | pve-2 |
| 03:20 | nightly checks — disk health, spin-down, git drift, vzdump age | pve-2 |
| weekly | Relay → Synology (cold storage) | pve-2 |
| 03:40 1st/mo | `media` scrub | pve-2 |
| 05:00 1st/mo | restic restore drill | pve-2 |
| 07:00 1st/mo (04:00 UTC) | Authentik/Joplin restore drill | VPS |

**They only interleave because Romania is UTC+3 in summer.** From late October
the UTC half drops to 01:40-02:02 local while the pve-2 half stays at 02:55-03:25,
and the SAS pool wakes twice a night instead of once, for about five months.

Accepted, not fixed. The ordering that actually matters still holds in both
seasons — every source writes before restic reads — and the only real fix is
moving eight cron jobs onto systemd timers pinned to UTC, which is a lot of new
surface to buy back one spin-up per night.

⚠️ **`CRON_TZ=UTC` is not the fix.** Debian's cron does not implement it — the
string is not even in the binary. It parses as an ordinary environment
assignment and is silently ignored, so the schedule keeps its local meaning.
Tried 2026-08-20 and reverted the next morning: it had moved the entire window
three hours early, which put restic ahead of every source that feeds it. One
night's Nextcloud, Longhorn, Immich, pfSense and VPS data missed the off-site
push and went out the following night instead.

## Fan control

The chassis fans run on [`scripts/fan-control.sh`](scripts/fan-control.sh)
under `fan-control.service`, not on iDRAC. iDRAC has no quieter setting left —
every thermal knob is at its minimum-cooling position and it still asks for
~3800 RPM with the pool parked. The floor is 1680 RPM, about -18 dB. Numbers
and reasoning: [known-issues.md](known-issues.md#fan-noise-idracs-floor-is-3800-rpm-the-hardwares-is-1680).

Manual mode has no dynamic response, so the script is it: CPU, hottest drive,
PERC ROC and exhaust every 30 s against a four-rung ladder.

| Rung | CPU | Drive | ROC | Exhaust | PWM | RPM |
|---|---|---|---|---|---|---|
| 0 | ≤55 | ≤42 | ≤78 | ≤50 | 0% | 1680 |
| 1 | ≤62 | ≤46 | ≤84 | ≤55 | 8% | 2900 |
| 2 | ≤68 | ≤49 | ≤88 | ≤60 | 16% | ~4300 |
| 3 | ≤73 | ≤52 | ≤92 | ≤65 | 28% | ~5400 |
| — | — | — | — | — | iDRAC | — |

Any one sensor over its ceiling steps up; all four must be 4 °C under to step
back down. Exhaust is the catch-all for what has no sensor — VRMs, RAM, the
idle Quadro.

Cooling returns to iDRAC on six paths: above the top rung, inlet >32 °C, an
unreadable or timed-out sensor, the script's `trap`, `ExecStopPost` (covers
SIGKILL), and `WatchdogSec=90` for a loop that wedges rather than dies.

```sh
/root/scripts/fan-control.sh --status    # sensors + live RPM
journalctl -u fan-control                # transitions only, not ticks
systemctl stop fan-control               # back to iDRAC, immediately
```

⚠️ A host that dies with the power on leaves the fans where the script left
them; a dead host makes no heat. A cold boot or iDRAC reset reverts to
automatic on its own and the loop reapplies within one cycle.

## Storage layout

`rpool`: ZFS mirror, 2× 960GB Intel SATA SSD (backplane slots 0-1). Boot
pool, every VM/LXC disk, `rpool/garage-meta`, `rpool/jellyfin-public`. 888G,
51% full (453G allocated, 2026-08-28). Was a 4-disk RAID10 until 2026-08-27,
when `mirror-1` was evacuated online and its two SSDs were pulled for the
OptiPlex nodes.

`media` pool: 2× RAIDZ2-6 (12× 600GB SAS), spin-down via the stateless
enforcer script (see [spindown-setup.md](spindown-setup.md)).

| Dataset | NFS export | Consumers |
|---|---|---|
| `media/library` | rw | Jellyfin (ro), Sonarr/Radarr/qBittorrent (rw) via `NFS_SERVER` var |
| `media/backups` | rw | Immich pg_dump CronJob, backup jobs |

`media/photos` and `media/isos` are no longer NFS-exported — both existed
only for Filebrowser, which was removed (Immich has its own Longhorn/SSD
storage and never used this export). The datasets themselves are untouched.

- Exports ACL: **per host, not the subnet** (narrowed 2026-08-11 — it was
  `10.57.57.0/24`, which with `no_root_squash` gave every device on the LAN
  root on the backup tree). Allowed clients: `10.57.57.80/82/84` (Talos
  nodes — all pod mounts originate there).
  Adding a client means adding its IP to `/etc/exports`, not widening back
  to `/24`. Previous file kept as `/etc/exports.bak-2026-08-11`.
- The ARR stack uses the `NFS_SERVER` cluster-var for its `media/library` mount.

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
├── dump/              vzdump images of VM 1000, weekly Sat 22:00, keep-last=3.
│                      Excluded from the restic push — see restic-push-oracle.sh
│                      for why — so the Synology pull is its only second copy.
├── nextcloud/         borg repo, nightly 02:40 (AIO schedules in UTC), written
│                      by the VM over a forced-command SSH key
│                      (borg-nextcloud account). See nextcloud/README.md.
├── pfsense/           config.xml.gz, nightly 03:00 (mode 0700)
├── longhorn-garage/   Garage data (live) + meta (nightly copy from SSD)
├── immich-postgres/   pg_dump, nightly 03:02 (k8s schedules in UTC), 30-day retention
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
  `garage_webui_enabled=false`).
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
| VPS → pve-2 | nightly 03:00 | SSH rsync push, rrsync-restricted key |
| pve-2 → Synology | weekly, in NAS wake window | rsync `--link-dest` versioned snapshots, 21-day retention |
| pve-2 → Oracle | nightly 03:10 | restic over SFTP, verified + monthly drill |
| ZFS snapshots | nightly 03:05 | `media/backups@daily-*`, 14-day retention |
| pfSense → pve-2 | nightly 03:00 | pfSense-side cron pushes `config.xml.gz` over a forced-command key |

Retired: Synology→Oracle HyperBackup (2026-07-26) — restoring its
proprietary vault needs a working DSM; the restic leg replaced it.

### pfSense → pve-2

- Push runs on the firewall:
  [`pfsense/scripts/backup-to-r730xd.sh`](../../pfsense/scripts/backup-to-r730xd.sh)
- pve-2 pins the key to a receiver:
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

### VPS → pve-2

`authorized_keys` line on pve-2 (restricted):

```
restrict,command="rrsync /media/backups/oracle-vps",from="10.57.57.1" ssh-ed25519 AAAA... oracle-vps-to-r730xd
```

⚠️ `from=` must be `10.57.57.1` (pfSense LAN) — pfSense NATs
Tailscale-routed traffic, so pve-2 never sees the VPS's Tailscale IP. Fails
silently otherwise; debug via `journalctl -u ssh` (no auth.log on this
host). Key rotation: regenerate on VPS, update
`vault_oracle_vps_to_r730xd_ssh_key` in the vps Ansible vault.

### Synology → pve-2

**Reversed on 2026-09-07.** This host used to push, holding a key into the NAS
and running `rsync --delete` against it, which made the NAS copy destroyable
from the machine whose compromise is the reason the copy exists. It now holds no
credential that reaches the NAS at all.

The NAS pulls instead, on its own schedule inside its wake window, using two
keys pinned in this host's `authorized_keys` to `rrsync -ro` over one directory
each and to the NAS's IP:

```
restrict,command="rrsync -ro /media/backups",from="10.57.57.201"  nas-pull-backups@storage
restrict,command="rrsync -ro /media/photos",from="10.57.57.201"   nas-pull-photos@storage
```

Two keys rather than one rooted at `/media`, so neither can reach
`/media/library` or `/media/isos`. Writing back returns "sending to read-only
server is not allowed"; anything that is not rsync returns "SSH_ORIGINAL_COMMAND
does not run rsync".

Retention (21 days, `--link-dest` versioning) moved to the NAS with the job. See
[`synology/README.md`](../../synology/README.md).

⚠️ Retention prunes by **date parsed from the folder name**, never `find
-mtime` — `rsync -a` copies source mtimes, which once made the script
delete a snapshot the moment it was created.

### pve-2 → Oracle (restic)

Open format — restorable anywhere with the `restic` binary + repo
password. Dest: chrooted SFTP-only user `restic-backup` on the VPS
(provisioned by the `vps_backup` role). Private key lives on pve-2 only.

Scope: everything under `/media/backups/`, plus `/media/photos` and
`/root`. No exclusions — every directory under `/media/backups/` is pushed.

`/root` was added 2026-08-11. Without it the cron scripts, `/root/.ssh`,
`PRIVATE-NOTES.md` and the restic password file existed on exactly one
disk, the one being backed up.

One-time setup on pve-2:

```bash
apt install -y restic
openssl rand -base64 32 > /root/.restic-oracle-password   # save in password manager!
chmod 600 /root/.restic-oracle-password
# The rest-server credential, separate from the repo password: it authenticates
# to the endpoint, it does not decrypt anything. Also in the password manager.
chmod 600 /root/.restic-rest-password
export RESTIC_PASSWORD_FILE="/root/.restic-oracle-password"
export RESTIC_REPOSITORY="rest:http://pve-2:$(cat /root/.restic-rest-password)@100.72.22.38:8000/"
restic init
```

The SFTP chroot this replaced was retired on 2026-09-07 and its key revoked;
`/srv/restic-repo/.ssh/authorized_keys` on the VPS is empty. Over SFTP this host
could delete the off-site copy. Over the append-only endpoint it cannot.

Nightly: [`scripts/restic-push-oracle.sh`](scripts/restic-push-oracle.sh),
cron `10 3 * * *`. Retention `--keep-daily 7 --keep-weekly 4
--keep-monthly 3`, then `restic check`. Pings healthchecks.io.

Restore from anywhere:

```bash
export RESTIC_PASSWORD_FILE=/path/to/password             # password manager
export RESTIC_REPOSITORY="rest:http://pve-2:$(cat /root/.restic-rest-password)@100.72.22.38:8000/"
restic snapshots && restic restore latest --target /tmp/restored
```

⚠️ **If pve-2 is gone, both credentials in that command are gone with it.**
`/root/.restic-rest-password` lives only on pve-2 — inside the backup it is
needed to open. The repo password is in the password manager; the rest-server
one is not the thing to go hunting for.

Do not try to restore the credential. Read the repository where it sits, on the
VPS, where no pve-2 secret is involved at all — only sudo there and the repo
password. Verified 2026-09-09:

```bash
# on the VPS
sudo docker run --rm -u 999:987 \
  -v /srv/restic-repo/data:/repo -v /etc/restic/repo-password:/pw:ro \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/pw \
  restic/restic:0.18.0 snapshots
```

This is also how `restic-retention.sh` reaches the repository, so it is a path
that runs nightly rather than one first tried during a disaster. `/etc/restic/repo-password`
on the VPS holds the same repo password as the password manager — if the VPS is
gone too, that is the copy you need.

`restrict` is not optional: without it the key is a general-purpose login on
the VPS rather than an SFTP-only one. Remove the line once recovery is done —
`make db-backups-setup` rewrites the file from
`vps_backup_restic_public_key` and will drop it anyway.

Monthly drill: [`scripts/restic-restore-drill.sh`](scripts/restic-restore-drill.sh),
cron `0 5 1 * *`. Restores pfsense + immich-postgres to a throwaway dir,
hash-compares against live source, pings healthchecks.io.

⚠️ The drill runs **on pve-2**, where the password file is present. It
proves the data is good; it cannot prove you can still open the repo
without pve.

Key rotation: new pair on pve-2 → update `vps_backup_restic_public_key` in
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

## UPS-triggered shutdown

The UPS (CyberPower VP700ELCD) is on **pve-2's own USB**, monitored by **NUT**.
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

NUT is used instead of PowerPanel (`powerpanel` is installed but
**masked/disabled** — leave it that way, the two fight over the same device)
because of a USB controller quirk specific to this chassis — do not
"simplify" this choice away without reading
[known-issues.md](known-issues.md#why-nut-not-powerpanel-for-the-ups) first.

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

## Alerting

Everything reports to **healthchecks.io**, nothing to local mail.

The four host checks share one healthcheck, not four. They run in sequence
from `nightly-checks.sh`, are silent unless something is wrong, and are all
investigated the same way — four separate checks would be four places to
look for one answer. Each sub-check just exits non-zero; the wrapper names
whichever failed: SAS health, spin-down drift, git drift, vzdump age.

`mail root` is a black hole on this host: no `/etc/aliases`, no `relayhost`,
and a test message on 2026-08-29 vanished without reaching a queue or a log.
The SAS health check and the spin-down drift check had used it since they
were written, so neither had ever reached a human. Both moved on 2026-08-29.

### Proxmox's own notifications go to Telegram

PVE has its own mechanism (`/etc/pve/notifications.cfg`) and the scripts should
not reach into it. Since 2026-09-09 it points at the same Telegram chat
Alertmanager and Flux already use, so there is one place to look rather than
three.

It used to send to an SMTP relay and a ProxMobo webhook, both replicated from
`px-0`. ProxMobo is gone: it registers a node by name, the 2026-09-04 rename from
`pve` to `pve-2` broke it, and nobody found out for five days because no
notification needed sending in between. The first one that did — a manual vzdump
on 2026-09-09 — returned HTTP 500. The app has since been uninstalled.

Recreate the target with the bot token and chat id from `PRIVATE-NOTES.md`.
Every value except the URL is base64, including the secret — passing the token
raw gets `could not decode base64 value with key 'token'`:

```bash
BODY=$(printf '{"chat_id":"<CHAT_ID>","text":"{{ escape title }}\n{{ escape message }}"}' | base64 -w0)
pvesh create /cluster/notifications/endpoints/webhook \
  --name telegram --method post \
  --url 'https://api.telegram.org/bot{{ secrets.token }}/sendMessage' \
  --header "name=Content-Type,value=$(printf 'application/json' | base64 -w0)" \
  --body "$BODY" \
  --secret "name=token,value=$(printf '<BOT_TOKEN>' | base64 -w0)"
pvesh set /cluster/notifications/matchers/default-matcher --target telegram
pvesh create /cluster/notifications/targets/telegram/test    # silence means it worked
```

`{{ secrets.token }}` keeps the token in `/etc/pve/priv/notifications.cfg`
(0600) rather than the world-readable config. The file is not in this repo: its
body carries the chat id, and base64 is not encryption.

`mail-from-cloud` stays defined but unmatched — an SMTP relay one line away from
being a fallback if the bot token is ever revoked. Nothing routes to it today.

healthchecks.io is also the only one of the three that reports a check which
stops running at all, which is the failure mode that matters most here.

## Site-alive heartbeat

Dead-man's switch for total site outage (power/WAN/pve down — nothing else
can report that). `/root/scripts/heartbeat-ping.sh`, cron `*/5 * * * *`,
pings healthchecks.io `homelab-heartbeat` (period 5min, grace 10min,
alerts via Email to hello@merox.dev — independent of the Telegram channel).

## Drives without SES temperature reporting make the fans scream

If all chassis fans suddenly ramp to ~8900 RPM with nothing actually hot: a
drive on the SAS backplane isn't answering SES temperature queries, and the
fan controller assumes the worst. Diagnose with:

```sh
for s in 0 1 16; do storcli /c0/e32/s$s show all | grep "Drive Temperature"; done
```

A healthy drive answers `25C`; the offending one answers `N/A`. Full
root-cause writeup and fix options:
[known-issues.md](known-issues.md#drives-without-ses-temperature-reporting-make-the-fans-scream).
