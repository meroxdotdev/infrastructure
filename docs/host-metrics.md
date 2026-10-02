# Host metrics on the Proxmox hosts

Back to: [architecture.md](architecture.md) ·
[`pve-1`](../proxmox/pve-1/README.md) · [`pve-2`](../proxmox/pve-2/README.md) ·
[`pve-3`](../proxmox/pve-3/README.md)

## What this fixes

`node_exporter` runs on the Talos VMs, so until 2026-09-11 every hardware
number in Grafana was measured from **inside a guest**. The three machines
underneath were visible only through the Proxmox API, which reports CPU,
memory and storage *totals* and nothing else.

What that left unmeasured:

| | Why it matters here |
|---|---|
| Disk wear | The Talos SSDs and the hosts' NVMe drives wear in proportion to etcd and Longhorn writes; the guests cannot see it |
| Per-disk I/O and latency | The etcd fsync stalls of 2026-08 were diagnosed by hand because nothing recorded disk latency on the host |
| Real memory pressure | The API reports allocated, not reclaimable |

## Install

Debian's package, on all three hosts, as root:

```bash
apt-get install -y prometheus-node-exporter
```

Then bind it to the LAN address. **Not `0.0.0.0`** — every one of these hosts
also carries a Tailscale interface, and host metrics have no business being
served there. This is the same reasoning as the explicit `LISTEN` lines in
[`pve-1`'s `upsd.conf`](../proxmox/pve-1/etc/nut/upsd.conf).

The config for each host is in git, one line each:
`proxmox/pve-<n>/etc/default-prometheus-node-exporter`. Copy it from a
checkout:

```bash
# pve-1 shown; pve-3 is the same with its own directory and 10.57.57.253
scp proxmox/pve-1/etc/default-prometheus-node-exporter root@10.57.57.254:/etc/default/prometheus-node-exporter
ssh root@10.57.57.254 systemctl restart prometheus-node-exporter
```

Keeping `--collector.textfile.directory` matters: it is the Debian default,
and dropping it silently removes everything in the next section.

## What apt brings along

`apt-get install prometheus-node-exporter` also pulls in
`prometheus-node-exporter-collectors` as a Recommends. It was not asked for,
and it turned out to be worth keeping — systemd timers that write `.prom`
files into the textfile directory:

| File | What it adds | Where |
|---|---|---|
| `smartmon.prom` | SMART health and SSD wear | pve-3 |
| `nvme.prom` | NVMe wear (`nvme_percentage_used_ratio`), media errors | pve-1, pve-3 |
| `apt.prom` | pending upgrades, reboot required | pve-1, pve-3 |

The vault is not here and is not meant to be: it is off most of the day, and
scraping a host that is usually down only produces a permanent alert. Its
disks report through TrueNAS's own alerts to Telegram, its daily run through
healthchecks.io. `pve-2` (the OptiPlex) has no node_exporter yet — see
[its README](../proxmox/pve-2/README.md).

The `zfs` and `hwmon` collectors are on by default and need no flag — they
activate where the kernel exposes them; none of these hosts runs ZFS, so they
report no pools.

## Verify

From the host:

```bash
curl -s http://10.57.57.254:9100/metrics | grep -c '^node_'
```

From the cluster, once Flux has reconciled the ScrapeConfig in
[`scrapeconfig.yaml`](../kubernetes/apps/observability/kube-prometheus-stack/app/scrapeconfig.yaml):

```bash
kubectl -n observability port-forward svc/prometheus-operated 9090:9090
curl -s --data-urlencode 'query=up{job="pve-node"}' localhost:9090/api/v1/query
```

One series per host, all `1`, each carrying a `host` label (`pve-1`, `pve-3`)
set by the ScrapeConfig. The Grafana dashboard **Node Exporter Full**
picks the hosts up on its own once the job reports — it is driven by a job
variable, not a hardcoded name.
