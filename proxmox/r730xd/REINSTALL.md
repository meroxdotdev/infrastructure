# pve (R730xd) — reinstall from bare metal

Checklist, not a tutorial. Rebuilds the *host*; the K8s cluster on top is
[`DR.md`](../../DR.md) / [`docs/dr-quickstart.md`](../../docs/dr-quickstart.md).

**You need:**

- Proxmox ISO, iDRAC or a crash cart, this repo
- `restic bak password` — decrypts the Oracle backup
- `age.key` — decrypts everything SOPS in this repo

⚠️ Neither secret is recoverable from a backup. Lose the restic password
and the Oracle leg goes with it, leaving only the Synology relay and the
ZFS snapshots — both on hardware in the same building.

**Survives:** the `media` pool (12× SAS). Import it, do not recreate it.
**Does not survive:** `rpool` (boot mirror, 4× Intel SSD) — takes
`rpool/garage-meta` and the Garage LXC's `subvol-103-disk-0` with it.

## 1. Controller first

PERC H730P must be in **HBA mode** before installing, or ZFS sees virtual
disks instead of the drives. See [`spindown-setup.md`](spindown-setup.md).

## 2. Install Proxmox

`rpool`, ZFS **RAID10** across the 4× 960GB Intel SSDs. Hostname `pve`,
IP `10.57.57.250/24`, gateway `10.57.57.1`.

Then match [`etc/network-interfaces`](etc/network-interfaces) — `vmbr0`
bridges `nic3`; `nic0`–`nic2` stay manual.

## 3. Import the SAS pool

```bash
zpool import                # confirm 'media' is seen, 2x raidz2-6
zpool import -f media
zfs list                    # library, backups, photos, isos, games
```

Datasets carry their own properties (`atime=off`, `xattr=sa`,
`compression=lz4`) — nothing to set.

## 4. Packages

```bash
apt update && apt install -y nfs-kernel-server sg3-utils smartmontools ipmitool restic rsync bc borgbackup
dpkg -i /media/backups/tools/storcli*.deb    # mirrored on purpose, no vendor URL needed
```

## 5. Storage + exports

```bash
cp <repo>/proxmox/r730xd/etc/storage.cfg /etc/pve/storage.cfg
cp <repo>/proxmox/r730xd/etc/exports     /etc/exports
exportfs -ra && exportfs -v
```

Export ACLs are per host. Adding a client means adding its IP, not widening
to `/24` — see [`README.md`](README.md).

Dataset properties do **not** come back with an import — reapply them:

```bash
zfs set reservation=150G media/backups   # backups cannot be starved by media
zfs set quota=3T media/library           # bulk media cannot eat the pool
```

Without the reservation, a large download fills the pool and the first thing
to fail with ENOSPC is the backup — the irreplaceable data loses the race to
the re-downloadable kind. Both were added 2026-08-17; `media/games` was
destroyed at the same time and should not be recreated.

## 6. Secrets and keys (restore, do not recreate)

From the restic repo — the only leg that has `/root`:

```bash
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
restic restore latest --target / --include /root      # prompts for the password
```

That returns `/root/scripts/`, `/root/.ssh/` (incl. `pve-to-synology`),
`/root/.restic-oracle-password` and `/root/PRIVATE-NOTES.md`.

If restic is unreachable, copy [`scripts/`](scripts/) from this repo
instead and paste the three `hc-ping.com` UUIDs back by hand.

Re-add the VPS's restricted push key to `/root/.ssh/authorized_keys` — the
`rrsync` line is in [`README.md`](README.md). `from=` must be `10.57.57.1`.

## 7. Schedule

```bash
crontab <repo>/proxmox/r730xd/etc/crontab
crontab -l
```

Two things that file cannot carry:

- The **weekly Synology push line is redacted** and must be added back from
  `/root/PRIVATE-NOTES.md`. It has to land inside the NAS wake window, which
  DSM keeps in its own local time.
- `vzdump` for VM 101 runs from cron, not from the Proxmox job scheduler, so
  the whole schedule is readable in one file. If `/etc/pve/jobs.cfg` is
  restored from [`etc/jobs.cfg`](etc/jobs.cfg) the job is already disabled
  there; confirm it stays that way, or the backup runs twice.

⚠️ **Do not add `CRON_TZ` to this crontab.** Debian's cron does not implement
it and ignores it silently, so every line keeps its local meaning while looking
like it was moved. See the warning in [`README.md`](README.md#nightly-schedule).

## 8. Spin-down

```bash
<repo>/proxmox/r730xd/install-spindown.sh --check
<repo>/proxmox/r730xd/install-spindown.sh
```

Generates `sas-disks.sh`, `sas-spindown.sh`, `sas-health-check.sh`,
`spindown-drift-check.sh` into `/root/scripts/`. Confirm with the
two-minute test in [`spindown-setup.md`](spindown-setup.md).

## 9. Garage LXC (103)

Rebuilt, not restored — the container is stateless:

```bash
cd <repo>/vps
ansible-playbook -i inventories/production/hosts playbooks/garage-setup-r730xd.yml
```

Its **data** is the bind mount on `media/backups/longhorn-garage/data`
(survived). Its **meta** lived on `rpool` and did not — copy it back from
`media/backups/longhorn-garage/meta/`, which the 03:01 cron mirrored
nightly. Then re-point Longhorn at the new key
(`minio-secret.sops.yaml`, see [`README.md`](README.md)).

## 10. VMs

- Talos control plane 800 → [`docs/dr-quickstart.md`](../../docs/dr-quickstart.md).
  One node since 2026-08-17, not three — see [`talos/SINGLE-NODE.md`](../../talos/SINGLE-NODE.md).
- home-assistant (101) → `qmrestore /media/backups/dump/<latest>.vma.zst 101`
- ollama (105) → `qmrestore /media/backups/dump/<latest>.vma.zst 105`.
  Keep IP `10.57.57.90`; the n8n alert-triage workflows point at it by address.
- nextcloud (1000) → not in `dump/`; rebuilt from its own borg archive.
  See [`nextcloud/README.md`](nextcloud/README.md) §6, and §10c below for the
  half of it that lives on this host.

## 10b. etcd snapshot credential

`scripts/etcd-snapshot.sh` needs `/root/.talos-etcd-backup`, which is a Talos
config carrying **only** the `os:etcd:backup` role. It is not in this repo and
not in any backup — it is a credential, and it is cheap to reissue:

```bash
talosctl -n 10.57.57.80 config new --roles os:etcd:backup \
  --crt-ttl 8760h /root/.talos-etcd-backup
chmod 600 /root/.talos-etcd-backup
```

Also needs `talosctl` on the host itself (`/usr/local/bin`, matching the
cluster's Talos version). Confirm the scope took: `talosctl reboot` with this
config must return `PermissionDenied`. If it reboots the node instead, you
generated an admin config and put it on the backup host.

⚠️ The cert expires one year out (issued 2026-08-17). Nothing warns you — the
snapshot job just starts failing, and it only writes to the log.

## 10c. Nextcloud borg repository

The repository itself is on the `media` pool and survives a reinstall — it
comes back with `zpool import media`. Three things around it do not, and
without them AIO cannot reach its own backups:

```bash
apt install -y borgbackup                       # already in §4
zfs create media/backups/nextcloud 2>/dev/null || true
useradd --system --create-home \
  --home-dir /var/lib/borg-nextcloud --shell /bin/bash borg-nextcloud
chown borg-nextcloud:borg-nextcloud /media/backups/nextcloud
chmod 700 /media/backups/nextcloud
install -d -m 700 -o borg-nextcloud -g borg-nextcloud /var/lib/borg-nextcloud/.ssh
```

Then authorise AIO's borg key. AIO regenerates it on first backup attempt and
prints it in its own interface; the line must keep the forced command, or the
key becomes a general-purpose shell login on this host:

```
command="borg serve --restrict-to-repository /media/backups/nextcloud",restrict ssh-ed25519 AAAA…
```

`0600`, owned by `borg-nextcloud`. Verify from the VM before trusting it —
authentication should be answered by borg itself, not a shell:

```bash
ssh -i <aio key> borg-nextcloud@10.57.57.250   # → "Borg 1.4.0: Got connection close…"
```

## 11. Verify

```bash
zpool status                                   # both pools ONLINE
exportfs -v                                    # per-host ACLs
crontab -l | wc -l                             # 8
systemctl is-active nfs-server smbd 2>/dev/null
restic snapshots --last                        # repo reachable
smartctl -i -n standby /dev/sdb                # parked after the idle delay
```

Mail for the SMART/health alerts must work or the checks fail silently —
send yourself a test before calling this done.
