# pve (R730xd) — reinstall from bare metal

Checklist, not a tutorial. Rebuilds the *host*; the K8s cluster on top is
[`DR.md`](../../DR.md) / [`docs/dr-quickstart.md`](../../docs/dr-quickstart.md).

**You need:** the Proxmox ISO, iDRAC or a crash cart, this repo, and two
secrets from the password manager — `restic bak password` (decrypts the
Oracle backup) and `age.key` (decrypts everything SOPS in this repo).

Neither is recoverable from a backup: the restic password protects the
repo that would hold a copy of it. If the vault entry is gone, the Oracle
leg is gone with it — the Synology relay and the ZFS snapshots are the
remaining copies, and both live on hardware in the same building.

**Survives a reinstall:** the `media` pool (12× SAS). Do not recreate it.
**Does not survive:** `rpool` (boot mirror, 4× Intel SSD) — that takes
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
apt update && apt install -y nfs-kernel-server sg3-utils smartmontools ipmitool restic rsync bc
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

- Talos control planes 800/802/804 → [`docs/dr-quickstart.md`](../../docs/dr-quickstart.md)
- home-assistant (101) → `qmrestore /media/backups/dump/<latest>.vma.zst 101`

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
