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
[`pve-2`'s `upsd.conf`](../proxmox/pve-2/etc/nut/upsd.conf).

The config for each host is in git, one line each:
`proxmox/pve-{1,2,3}/etc/default-prometheus-node-exporter`. On pve-2,
[`reinstall.sh`](../proxmox/pve-2/reinstall.sh) installs the package and the
file. On the other two, copy it from a checkout:

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
| `smartmon.prom` | SMART health and SSD wear | pve-2, pve-3 |
| `nvme.prom` | NVMe wear (`nvme_percentage_used_ratio`), media errors | all three |
| `ipmitool_sensor.prom` | PSU draw, inlet/exhaust temperature, fan RPM from iDRAC | pve-2 |
| `apt.prom` | pending upgrades, reboot required | all three |

⚠️ **The first worry on pve-2 is the SAS spin-down, and it holds.** `smartmon`
polls every disk every 15 minutes, and a SMART query can spin up a parked
drive — which is what produced the etcd stalls of 2026-08. Checked 2026-09-11:
it reports all twelve SAS disks as `smartmon_device_active 0` (standby) and
skips them, and the UPS draw stayed flat at 164 W across a run. SMART on the
SAS disks therefore stays with `sas-health-check.sh`, inside the nightly wake
window, and this collector covers the SSDs. **If a future package version
stops respecting standby, mask `prometheus-node-exporter-smartmon.timer` on
pve-2** — do not remove the package, the other three collectors are fine.

The same directory carries two files of this repo's own, written by the
nightly scripts on pve-2 when they succeed:

| File | Written by | Leg |
|---|---|---|
| `backup-offsite.prom` | `restic-push-oracle.sh` | restic → Oracle, nightly |
| `backup-vm-image.prom` | `vzdump-freshness-check.sh` | vzdump of VM 1000, weekly |

Both publish `backup_last_success_timestamp_seconds{leg=...}`, which is what
the Homelab Overview's backup tiles read. Healthchecks.io remains the alert for
both legs — these are visibility, not a second pager.

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

Three series, all `1`, each carrying a `host` label (`pve-1`, `pve-2`,
`pve-3`) set by the ScrapeConfig. The Grafana dashboard **Node Exporter Full**
picks the hosts up on its own once the job reports — it is driven by a job
variable, not a hardcoded name.
