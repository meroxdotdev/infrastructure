# 2026-11-08 — `kubernetes-1`: one vCPU stuck in the kernel, etcd stalls

**Status: open, diagnosed to the mechanism, not to the culprit.** Written
2026-11-10 ~10:15 UTC as a handoff. Nothing was changed on the cluster or the
hosts; everything below was read from Prometheus and Loki. All times are UTC
(Romania is UTC+2).

## Symptom

Telegram has alternated `EtcdFailedGRPCRequests` firing/resolved since
2026-11-08, for `instance=10.57.57.80:2381`, `grpc_method=Txn`.
`EtcdSlowFsyncBurst` has been firing without a break over the same period.

The alerts are correct. Do not silence them and do not move the thresholds.

## What is happening

Only `kubernetes-1` (VM 810 on `pve-1`) is affected. Quorum holds on the other
two members and `kubernetes-2` is the leader, so the cluster works.

| Measured on `kubernetes-1` | Before | Since 2026-11-08 16:40 |
|---|---|---|
| WAL fsyncs over 1 s, per hour | 0 | ~97, flat |
| Shape of those fsyncs | — | under 128 ms, or over 4 s (most over 8 s); nothing in between |
| Seconds spent in WAL fsync, per minute | 1.7 | ~20 |
| System CPU, cores | 0.33 | 1.27 |
| `node_load5` | ~1.5 | ~7 |
| CPU pressure (waiting) | as the other nodes, ~0.06 | 0.50 |

The other two nodes show zero slow fsyncs throughout.

The cause of the stalls is one vCPU held in kernel mode:

- One CPU sits at 99.8 % `system`. All others are at ~2.5 %.
- On that CPU the scheduler records about **1 timeslice per second**, against
  ~1600 on its neighbours. Something in the kernel runs there and does not
  yield.
- Tasks queued on that CPU wait 3.2 s per second
  (`node_schedstat_waiting_seconds_total`).
- It was **cpu 6** from the first boot (2026-11-08 16:48) until the reboot of
  2026-11-09 17:30, and **cpu 10** since. So it is not tied to one vCPU or one
  interrupt line; it starts again at every boot.

The working explanation for the fsync shape: the disk finishes on time, but
whatever completes the fsync is sometimes queued on the held CPU and waits
there. This part is inference, not measurement.

Downstream effects, all on `kubernetes-1` only:

- `kube-apiserver-kubernetes-1` logs `etcdserver: request timed out` and
  `Failed to update lease` in bursts, and has restarted several times.
- `etcd_server_slow_apply_total` ~1860/h, `slow_read_indexes` ~150/h,
  1213 failed proposals in 7 days (94 and 48 on the other members).
- 8–10 leader elections seen in 7 days, most of them around the reboots.

Why the gRPC alert flaps: it needs more than 1 % of unary `Txn` calls failing
for 10 minutes, and `kubernetes-1` only serves ~0.3 Txn/s. Each burst of
timeouts crosses 1 % and the next quiet stretch drops back under it.

## Timeline

| When | What |
|---|---|
| 2026-11-08 09:52–09:56 | Renovate PRs #900–#909 merge. No change in the node's CPU or fsyncs afterwards. |
| 2026-11-08 ~16:37 | `pve-1` and `pve-2` go down together. `nvme_unsafe_shutdowns_total` +1 on every NVMe in both. The UPS exporter recorded no on-battery state (it is scraped through `pve-1`, so a gap proves little). |
| 2026-11-08 16:48 | First samples after boot: cpu 6 of `kubernetes-1` already at 99.7 % system, slow fsyncs begin. Kernel on the host is still `7.0.14-25-pve`. |
| 2026-11-09 ~07:20 | `pve-3` goes down uncleanly too (unsafe shutdown +1). `kubernetes-3` is fine afterwards. |
| 2026-11-09 16:50–17:35 | All three hosts reboot into `7.0.14-28-pve`. On `kubernetes-1` the held CPU moves from 6 to 10; nothing else changes. |

## Ruled out

- **The new Proxmox kernel.** The problem began on `-25`, a day before `-28`.
- **The physical disk, as far as metrics can tell.** Average write and flush
  latency are normal in the guest (`sda`) and on the host; the device is not
  busy for anything like the 16+ s/min the stalls would need; no NVMe media
  errors or new error-log entries; 46 °C.
- **etcd's backend on the same filesystem.** Not one backend commit over 1 s.
  Only the WAL fsync stalls.
- **Clock.** NTP in sync, offset under 1 ms on every node and host.
- **More load.** Same pod count (52 → 55), slightly *less* written to `sda`.
- **A repo change, mostly.** Ten Renovate PRs (#900–#909) merged at
  09:52–09:56 on 2026-11-08, among them kube-prometheus-stack 92 → 93,
  prometheus-operator-crds 33, coredns and the `bpg/proxmox` Terraform provider.
  System CPU on the node stayed at 0.35 cores for the seven hours between those
  merges and the power cut, so none of them started it on a running node. What
  that does not exclude is one of them behaving differently on a fresh boot;
  low suspicion, but `processes --sort cpu` settles it either way.
- **A reboot as the fix.** The VM has been restarted once since; it came back
  the same.

## Not known

Which kernel thread or code path is holding the CPU. Candidates, none
supported by evidence yet: XFS on `/var` (`sda4`) left inconsistent by the
power cut on a drive with no power-loss protection; a driver, the passed-through
Iris Xe being the one thing only this node has; a flood of kernel messages to a
slow console.

An earlier guess in this investigation was "wipe `EPHEMERAL` and rejoin", from
the 2026-09-07 note in [../../proxmox/pve-1/README.md](../../proxmox/pve-1/README.md).
**Do not do that yet.** That incident was a user-space spin; this one is in the
kernel, and a wipe is only the right fix if the filesystem is the culprit.

## Next step

Needs `talosctl` (v1.14.4, `TALOSCONFIG=talos/clusterconfig/talosconfig`).
Read-only:

```bash
talosctl -n 10.57.57.80 processes --sort cpu     # what holds the core
talosctl -n 10.57.57.80 dmesg                    # XFS, I/O, i915, soft lockups, RCU stalls
talosctl -n 10.57.57.80 read /proc/interrupts    # only if the two above are quiet
talosctl -n 10.57.57.80 etcd status
talosctl -n 10.57.57.80 etcd alarm list
```

On `pve-1`, also read-only:

```bash
journalctl -k -b | grep -iE 'nvme|i/o error|thin|vfio|kvm'
lvs -a -o+seg_monitor,lv_health_status cluster-storage   # thin pool state after the power cut
qm config 810
```

Then, depending on what holds the core:

| Finding | Fix |
|---|---|
| An XFS thread (`xfsaild`, `xfs-*` workers), or XFS errors in `dmesg` | Wipe `EPHEMERAL` on `kubernetes-1` and let it rejoin. Follow the Longhorn order in the pve-1 README; the node holds one replica of every volume, so check the other two replicas are healthy first. |
| `i915` / the passed-through GPU | Detach `hostpci0` from VM 810, confirm the CPU is released, then find why before re-attaching. Jellyfin loses hardware transcoding meanwhile. |
| Console / `printk` flood | Fix whatever is logging; the flood is the symptom. |
| LVM-thin pool flagged `needs_check` or errors on the host | Repair on the host, with the VM off. Not a guest problem. |
| Something else | Stop and read before acting. |

Whichever it is, verify with the queries below: system CPU on the node back to
~0.33 cores and slow fsyncs at zero for a full hour.

## So it does not happen again

To do once the culprit is known — not done yet:

1. **Find out why two hosts on the UPS lost power at 16:37 on 2026-11-08**, and
   `pve-3` the next morning. If these were not deliberate, the UPS did not do
   its job, and that is the root cause of this incident. Check
   `journalctl -u nut-monitor` and `last -x` on each host. The 2026-10-02 sag
   note in the pve-1 README is the same family of problem.
2. **Alert on a CPU held in the kernel.** Nothing watches for it, so this
   surfaced as two days of etcd alerts instead of one alert naming the cause.
   Sketch, to be tested against these two days of data before merging:

   ```yaml
   - alert: NodeCpuStuckInKernel
     expr: rate(node_cpu_seconds_total{mode="system"}[10m]) > 0.9
     for: 15m
     labels:
       severity: warning
   ```
3. **Ship Talos kernel and service logs to Loki.** Loki has pod logs only;
   neither `dmesg` nor the `etcd` service is there, which is why this could not
   be finished from metrics.
4. The disk table in [../../proxmox/pve-1/README.md](../../proxmox/pve-1/README.md)
   has the two NVMe names the wrong way round again: `cluster-storage`
   (serial `24534D2A66C6`, 38 % worn) is `nvme0n1` today, and was three days
   ago. Go by serial, as that README already says.

## Queries

Prometheus is at `https://prometheus.k8s.merox.dev`. Loki is reachable through
Grafana's datasource proxy:
`https://grafana.k8s.merox.dev/api/datasources/proxy/uid/loki/loki/api/v1`.

```promql
# Slow WAL fsyncs per member, last hour. Healthy is 0.
sum by (instance)(increase(etcd_disk_wal_fsync_duration_seconds_count[1h]))
  - sum by (instance)(increase(etcd_disk_wal_fsync_duration_seconds_bucket{le="1.024"}[1h]))

# The held CPU. Healthy is ~0.025 on every CPU.
topk(3, rate(node_cpu_seconds_total{instance="10.57.57.80:9100",mode="system"}[10m]))

# Timeslices per second, per CPU. The held one shows ~1.
rate(node_schedstat_timeslices_total{instance="10.57.57.80:9100"}[10m])

# Total system CPU on the node. Healthy is ~0.33.
sum(rate(node_cpu_seconds_total{instance="10.57.57.80:9100",mode="system"}[30m]))

# Failed unary calls by member, method and code.
sum by (instance,grpc_method,grpc_code)(
  increase(grpc_server_handled_total{job="kube-etcd",grpc_type="unary",grpc_code!="OK"}[1h])) > 0

# Unclean power-offs, per drive.
changes(nvme_unsafe_shutdowns_total[30m])
```

```logql
{pod="kube-apiserver-kubernetes-1"} |~ "etcdserver: request timed out|Failed to update lease"
```
