# Dell OptiPlex 3050 — `pve-3`, `10.57.57.253`

Standalone Proxmox host, not clustered with `pve-1` or `pve-2`. Carries no
guests yet; it exists to become the third fault domain for etcd.

Prepared 2026-09-04 from what used to be `px-2`.

| | |
|---|---|
| CPU / RAM | i5-6500T (4C/4T, Skylake, 35 W), 32 GB DDR4 (2x16) |
| `nvme0n1` | ADATA SX6000LNP 120 GB — Proxmox root. LVM: `pve-root` 39.6 G, `pve-swap` 8 G, `local-lvm` thin pool 60 G. **8% worn**, 1444 hours |
| `sda` | Intel D3-S4510 960 GB SATA, **power-loss protection**. 8931 hours, 0 reallocated sectors, wear indicator untouched. **Held empty on purpose** |
| Network | 1x 1 GbE `enp2s0` → `vmbr0`. `b8:85:84:ab:23:c3` |
| Power | ~10-14 W idle, estimated. It is not on the UPS bank NUT can read, so the draw was never measured directly |

## The two disks have different jobs

`sda` is reserved for a raw passthrough into the Talos VM, so Talos writes
straight to the SSD with no ZFS zvol underneath it. That avoids the write
amplification measured on `pve-1`, where a 16K `volblocksize` sits under 4K
guest writes. It is also the only disk in the fleet with power-loss
protection, which is what makes it the right home for etcd.

Everything else — Proxmox itself, and any management guest — goes on the
ADATA. Nothing else is to be placed on `sda`.

## No out-of-band management

There is no iDRAC and no configured AMT. If this host does not boot, it needs
a monitor and a keyboard.

Wake-on-LAN does work (`wakeonlan b8:85:84:ab:23:c3` from the LAN), but the
`ethtool -s enp2s0 wol g` that enables it does not survive a reboot, and the
BIOS side was never verified. Do not rely on it for recovery.

## What the 2026-09-04 cleanup removed

It had been a member of `PX-Cluster`, a three-node cluster whose other two
members left long ago. With 1 vote against a quorum of 3, corosync had
`/etc/pve` frozen read-only, so nothing could be created on it.

- Left the cluster: corosync stopped, disabled, and its config removed
- Node directories for `px-0`, `px-1`, `px-2` and the cluster's HA config
- Storage definitions cut from six to one (`local`); `local-lvm` added after
- Orphan VM 104 (`kubernetes-controlplane-3`), pointing at a volume group that no longer existed
- SSH keys cut from 13 to 2 — the rest were peer keys from decommissioned nodes
- A `bookworm` APT repository left over from the PVE 8 to 9 upgrade, on a `trixie` system. It was why the host sat at 9.2.4 while the others ran 9.2.11
- 21 of 25 installed kernels, and the APT cache. Root went from 79% to 17%

## Bootloader

GRUB EFI, **not** `proxmox-boot-tool` — `/etc/kernel/proxmox-boot-uuids` does
not exist here. `/boot/efi` is `nvme0n1p2`; the active NVRAM entry is
`Boot0005 proxmox`. `GRUB_DEFAULT=0` and the first menu entry is the newest
kernel, so a plain `apt` kernel upgrade is enough. Check `grub.cfg` before
rebooting; nothing here can be fixed remotely if it boots wrong.

A stale `Windows Boot Manager` entry remains in NVRAM from before. Harmless.
