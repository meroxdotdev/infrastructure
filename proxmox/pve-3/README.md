# Dell OptiPlex 3050 — `pve-3`, `10.57.57.253`

Standalone Proxmox host, not clustered with `pve-1` or `pve-2` — the three are
joined through Proxmox Datacenter Manager instead, never corosync.

Two guests: **VM 812** `kubernetes-3`, the third etcd vote and one of the two
Longhorn replicas, and **CT 100** `pdm`, the Datacenter Manager itself.

Prepared 2026-09-04 from what used to be `px-2`.

| | |
|---|---|
| CPU / RAM | i5-6500T (4C/4T, Skylake, 35 W), 32 GB DDR4 (2x16) |
| `nvme0n1` | ADATA SX6000LNP 120 GB — Proxmox root. LVM: `pve-root` 39.6 G, `pve-swap` 8 G, `local-lvm` thin pool 60 G. **8% worn**, 1444 hours |
| `sda` | Intel D3-S4510 960 GB SATA, **power-loss protection**. 8931 hours, 0 reallocated sectors, wear indicator untouched. Passed raw into VM 812 |
| Network | 1x 1 GbE `enp2s0` → `vmbr0`. `b8:85:84:ab:23:c3` |
| Power | ~10-14 W idle, estimated. It is not on the UPS bank NUT can read, so the draw was never measured directly |

## The two disks have different jobs

`sda` is passed raw into VM 812, so Talos writes straight to the SSD with no
ZFS zvol underneath it. That avoids the write
amplification measured on `pve-1`, where a 16K `volblocksize` sits under 4K
guest writes. It is also the only disk in the fleet with power-loss
protection, which is what makes it the right home for etcd.

Everything else goes on the ADATA: Proxmox itself, and the `local-lvm` thin
pool carved out of the 70 GB the installer left unallocated, which is where
the PDM container lives. Nothing else is to be placed on `sda` — it belongs to
etcd and one Longhorn replica.

## Proxmox Datacenter Manager lives here

CT 100, `pdm`, `10.57.57.57`, reachable at `https://dc.merox.dev`.

It used to be an 8 GB VM on `pve-1`. That was the wrong host: a management
plane that dies with the machine running the Kubernetes cluster is unavailable
exactly when it is wanted. `pve-3` is the box whose loss changes nothing, so
that is where it belongs. PDM has no HA of its own and does not need any —
every host still serves its own UI on `:8006`, and PDM's entire state is about
15 MB under `/etc` and `/var/lib/proxmox-datacenter-manager`.

Installed with `proxmox-datacenter-manager-container-meta`, which keeps the
host kernel. The plain `-meta` package came along with it and pulled three
Proxmox kernels into a container that cannot use one; they were purged. If a
future upgrade drags them back, purge again — nothing in a container boots
them.

### Certificate

Let's Encrypt, via DNS-01 against Cloudflare, renewed automatically by
`proxmox-datacenter-manager-daily-update.timer` once it expires within 30
days. Three pieces, and only the last has no CLI:

| What | Where |
|---|---|
| ACME account | `acme account register default hello@merox.dev --directory https://acme-v02.api.letsencrypt.org/directory` — interactive, answer `y` then `n` |
| Cloudflare plugin | `acme plugin add dns cloudflare --api cf --data <file>`, file containing `CF_Token=…`. The same token cert-manager uses, from `kubernetes/apps/cert-manager/cert-manager/app/secret.sops.yaml` |
| Domain | Web UI only: **Certificates → ACME Domains → Add**, `dc.merox.dev` with plugin `cloudflare`, then **Order Certificates** |

The domain lands in `/etc/proxmox-datacenter-manager/acme/certificate.cfg`,
**not** `domains.cfg` as the documentation says. There is no CLI to write it;
`acme certificate order` reports `No domains configured` until the UI has been
used once.

> **`acme plugin list` and `acme plugin config <id>` print the Cloudflare token
> in clear text.** That is how the token was leaked on 2026-09-05 and had to be
> rolled. To check the stored value, hash it instead:
> ```
> awk '/^dns: cloudflare/{f=1} f&&/data/{print $2; exit}' \
>   /etc/proxmox-datacenter-manager/acme/plugins.cfg | base64 -d | sha256sum
> ```
> To change it, `acme plugin set cloudflare --data <base64>` — note that `set`
> takes base64 on the command line while `add` takes a file path.

### Port 443

PDM serves only on 8443 and the port is not configurable, so
`https://dc.merox.dev` with no port reached nothing. `pdm-443.socket` and
`pdm-443.service` pass 443 through to 8443 with `systemd-socket-proxyd` — no
netfilter, which an unprivileged container could not use anyway. TCP is
forwarded untouched, so PDM still terminates TLS with its own certificate.

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
