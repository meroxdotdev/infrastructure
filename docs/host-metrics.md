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
| ZFS pool state and ARC | `rpool` and `media` live on `pve-2`. Pool health was watched only by `sas-health-check.sh` mailing on errors, once a night |
| Chassis and drive temperature | The R730xd's fan curve is driven by drive temperature, and one silent drive takes every fan to 8900 RPM — see [`known-issues.md`](../proxmox/pve-2/known-issues.md) |
| Per-disk I/O and latency | The etcd fsync stalls of 2026-08 were diagnosed by hand because nothing recorded disk latency on the host |
| Real memory pressure | The API reports allocated, not reclaimable |

It is also what turns the ZFS alert rule and the ZFS dashboard back on. Both
were disabled, and the comments say why in as many words: the metric exists
only where `node_exporter` runs, and it did not run where the ZFS was.

## Install

Debian's package, on all three hosts, as root:

```bash
apt-get install -y prometheus-node-exporter
```

Then bind it to the LAN address. **Not `0.0.0.0`** — every one of these hosts
also carries a Tailscale interface, and host metrics have no business being
served there. This is the same reasoning as the two explicit `LISTEN` lines in
[`pve-2`'s `upsd.conf`](../proxmox/pve-2/etc/nut/upsd.conf):

```bash
# pve-1: 10.57.57.254   pve-2: 10.57.57.250   pve-3: 10.57.57.253
cat >/etc/default/prometheus-node-exporter <<'CONF'
ARGS="--web.listen-address=10.57.57.250:9100 --collector.textfile.directory=/var/lib/prometheus/node-exporter"
CONF
systemctl restart prometheus-node-exporter
```

Keeping `--collector.textfile.directory` matters: it is the Debian default,
and dropping it would quietly remove the one hook the nightly scripts could
use later to publish their own results as metrics.

The `zfs` and `hwmon` collectors are on by default and need no flag — they
activate where the kernel exposes them, which is why `pve-3` will simply
report no pools.

## Verify

From the host:

```bash
curl -s http://10.57.57.250:9100/metrics | grep -c '^node_'
curl -s http://10.57.57.250:9100/metrics | grep '^node_zfs_zpool_state'
```

From the cluster, once Flux has reconciled the ScrapeConfig in
[`scrapeconfig.yaml`](../kubernetes/apps/observability/kube-prometheus-stack/app/scrapeconfig.yaml):

```bash
kubectl -n observability port-forward svc/prometheus-operated 9090:9090
curl -s --data-urlencode 'query=up{job="pve-node"}' localhost:9090/api/v1/query
```

Three series, all `1`. The Grafana dashboard **Node Exporter Full** picks the
hosts up on its own once the job reports — it is driven by a job variable, not
a hardcoded name.
