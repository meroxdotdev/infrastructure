# Dell OptiPlex 3050 — `pve-2`, `10.57.57.252`

Standalone Proxmox host, not clustered with `pve-1` or `pve-3` — the three are
joined through Proxmox Datacenter Manager, never corosync.

One guest: **VM 811** `kubernetes-2`, the second etcd vote and a Longhorn
replica. It took the name, MAC and IP of the `kubernetes-2` that ran on the
R730xd until 2026-09-29, so the cluster saw the same node come back on new
hardware.

The same model as `pve-3` and set up the same way: Talos gets an Intel
D3-S4510 passed through raw, the only disks in the fleet with power-loss
protection, which is what makes them the right home for etcd.

| | |
|---|---|
| CPU / RAM | i5 (4C/4T), 32 GB |
| `nvme0n1` | ADATA SX6000LNP 120 GB — Proxmox root |
| `sda` | Intel D3-S4510 960 GB, power-loss protection — passed raw into VM 811 |
| VM 811 | 3 cores, 16 GB; the rest of the host is left for test VMs |
| UPS | NUT secondary of `pve-1` |
| Metrics | node_exporter on `10.57.57.252:9100`; pve-exporter module `pve-2`, token `prometheus@pve!prometheus` (PVEAuditor) |

The name `pve-2` belonged to the R730xd until 2026-09-29. That machine is now
the [vault](../../truenas/README.md); nothing about it lives here any more.

## APT

Since 2026-10-02 the same as pve-3: `proxmox.sources` (no-subscription) and
`pve-enterprise.sources` with `Enabled: false`. The installer had left the
enterprise repository on — every `apt update` failed with 401, so the host had
taken no update since it was installed — plus a `bookworm` (Proxmox 8) line
in `pve-install-repo.list` on a `trixie` system, the same mixed-suite trap
pve-3 had until 2026-09-04.

## What this directory deploys

`etc/` mirrors real paths on the host.

| File | Host path | After copying |
|---|---|---|
| [`etc/default-prometheus-node-exporter`](etc/default-prometheus-node-exporter) | `/etc/default/prometheus-node-exporter` | `apt install prometheus-node-exporter` **first**, then `systemctl restart prometheus-node-exporter` — see [host-metrics.md](../../docs/host-metrics.md). Copying the file before the install makes dpkg stop at a conffile prompt; answer with `--force-confold` |
| [`etc/nut/nut.conf`](etc/nut/nut.conf) | `/etc/nut/nut.conf` | |
| [`etc/nut/upsmon.conf`](etc/nut/upsmon.conf) | `/etc/nut/upsmon.conf` | put the `upsslave` password from `pve-1`'s `upsd.users` in place of the redaction, `systemctl restart nut-monitor` |

## Related

[../pve-1/README.md](../pve-1/README.md) ·
[../pve-3/README.md](../pve-3/README.md) ·
[../../talos/THREE-NODE.md](../../talos/THREE-NODE.md)
