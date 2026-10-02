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
| VM 811 | 3 cores, 16 GB, the D3-S4510 raw |
| UPS | NUT secondary of `pve-1` |

The name `pve-2` belonged to the R730xd until 2026-09-29. That machine is now
the [vault](../../truenas/README.md); nothing about it lives here any more.

## Not yet

- **No metrics.** node_exporter and a pve-exporter module are not installed,
  so Prometheus, Grafana and the Homepage card see `pve-1` and `pve-3` only.
  Needs the workstation's key in `root@10.57.57.252`'s `authorized_keys`, then
  the same steps as [pve-3](../pve-3/README.md#what-this-directory-deploys)
  and a `pve-2` module in pve-exporter's secret.

## What this directory deploys

`etc/` mirrors real paths on the host.

| File | Host path | After copying |
|---|---|---|
| [`etc/nut/nut.conf`](etc/nut/nut.conf) | `/etc/nut/nut.conf` | |
| [`etc/nut/upsmon.conf`](etc/nut/upsmon.conf) | `/etc/nut/upsmon.conf` | put the `upsslave` password from `pve-1`'s `upsd.users` in place of the redaction, `systemctl restart nut-monitor` |

## Related

[../pve-1/README.md](../pve-1/README.md) ·
[../pve-3/README.md](../pve-3/README.md) ·
[../../talos/THREE-NODE.md](../../talos/THREE-NODE.md)
