# px-0 (Beelink GTi 13 Pro) — reinstall from bare metal

Checklist, not a tutorial.

⚠️ **Not currently deployed (2026-08-25)** — this hardware isn't running
Proxmox right now (out of scope, possibly a future dev cluster, not
decided). Kept as a rebuild reference for if/when that changes, not as an
active DR target — see [`README.md`](README.md).

⚠️ **Nothing on px-0 is backed up** — no vzdump job, no `jobs.cfg`, both
dump directories empty (verified 2026-08-11). All three VMs are rebuilt,
not restored. Acceptable because none holds unique data, but a disk
failure loses the VMs, not just the host.

Hardware: i9-13900H, 64GB, 2× 931GB Crucial P3 NVMe.

- `nvme1n1` — boot (LVM/ext4, `pve-root` 96G + 8G swap)
- `nvme0n1` — `cluster-storage`, single-disk ZFS, **no redundancy**

## 1. Install Proxmox

Hostname `px-0`, IP `10.57.57.254/24`, gateway `10.57.57.1`, onto
`nvme1n1`. Then match [`etc/network-interfaces`](etc/network-interfaces) —
`vmbr0` bridges `enp89s0`; `enp90s0` and `wlp88s0` stay manual.

## 2. Second NVMe

```bash
zpool create -o ashift=12 -O compression=lz4 -O mountpoint=/cluster-storage \
  cluster-storage /dev/disk/by-id/nvme-CT1000P3PSSD8_<serial>
mkdir -p /local_data
```

`/local_data` is a plain directory on the boot disk (ISOs, templates,
snippets) — not a pool.

## 3. Storage

```bash
cp <repo>/proxmox/px-0/etc/storage.cfg /etc/pve/storage.cfg
```

Defines:

- `local` (disabled), `local-data`, `cluster-storage`
- `r730xd-backups` — NFS `10.57.57.250:/media/backups`, the DR-test target
- `synology-nas` — NFS `10.57.57.201:/volume1/Server`. Shows inactive
  whenever the NAS is asleep; normal, not a fault.

⚠️ pve's export ACL is per host — `10.57.57.254` must be listed in
[`../r730xd/etc/exports`](../r730xd/etc/exports) or the mount is refused.

## 4. VMs

| VMID | What | How |
|---|---|---|
| 105 | `ollama` | [`README.md`](README.md) — full recreate script |
| 100 | `datacenter-manager` | Fresh install from the Proxmox Datacenter Manager ISO, then re-add `pve` and `px-0` as endpoints. Links the two hosts without a corosync cluster; holds no state worth keeping. |
| 102 | `winserver` | AD lab, kept powered off. Rebuild only if you actually want it. |

## 5. Verify

```bash
zpool status cluster-storage        # ONLINE
pvesm status                        # r730xd-backups active
ls /mnt/pve/r730xd-backups/         # readable
qm list
```

px-0 is also the default DR-test target — see
[`docs/dr-quickstart.md`](../../docs/dr-quickstart.md) for the values it
expects (`cluster-storage`, `local-data`, `vm_memory_mb 16384`).
