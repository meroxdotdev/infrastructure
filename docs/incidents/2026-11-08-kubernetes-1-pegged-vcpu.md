# 2026-11-08 — `kubernetes-1`: one vCPU stuck in the kernel, etcd stalls

**Status: fixed 2026-11-10 16:34 UTC** — `vga: none` on VM 810, verified on a
cold boot. Diagnosed from Prometheus, Loki, `talosctl` and the QEMU
monitor on `pve-1`. All times are UTC (Romania is UTC+2).

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
  interrupt line; it starts again at every cold boot. It is a work item that
  gets requeued, not a fixed spin: when one blit finished on 2026-11-10 the
  next one started on cpu 6.

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
| 2026-11-10 ~16:00 | `talosctl` and the QEMU monitor identify the busy task: `kworker/10:0+events`, copying the boot framebuffer at ~760 KB/s. |
| 2026-11-10 16:18 | Console switched to tty1. System CPU back to ~2.5 % per vCPU. |
| 2026-11-10 16:34 | VM 810 cold-booted with `vga: none`. No boot framebuffer; clean since. |

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

## Root cause

A framebuffer copy that the hypervisor traps byte by byte, re-triggered for
ever by the Talos dashboard.

1. VM 810 has two display devices: QEMU's emulated VGA (`00:01.0`, OVMF's boot
   framebuffer, 1280×800) and the passed-through Iris Xe (`06:10.0`).
2. On a cold boot, `simpledrm` takes the boot framebuffer at `0x80000000`
   (`BOOTFB` in `/proc/iomem`) and fbcon renders tty2 to it.
3. When `i915` probes, the VGA arbiter turns off decoding on the emulated VGA:
   its `PCI_COMMAND` reads `0x0004` on `kubernetes-1` against `0x0007` on
   `kubernetes-2`, and `info pci` in the QEMU monitor shows its BAR0
   `not mapped`. `simpledrm` keeps writing there anyway.
4. Every write to that unmapped range is a VM exit to QEMU: measured at
   **~760 KB/s**, so one full-screen blit (4,096,000 bytes) takes **~5.4 s**.
5. The Talos dashboard repaints tty2 about 6 times a second. The fbdev damage
   worker (`kworker/N:M+events`) never catches up and copies full frames back to
   back. That is the 100 % `system` CPU, and the WAL fsync completions queued
   behind it are the etcd stalls.

Evidence for the blit: vCPU 10 sampled from the QEMU monitor sat on one
instruction (`rep movsb`) in 39 of 40 samples, with `RCX` counting down inside
a 0x1400-byte (1280 × 4) line and `RDI` walking a 0x3e8000-byte buffer, then
wrapping. The stack held a `drm_rect` of `(0,0)–(1280,800)` and the fourcc
`XR24`. `/proc/69/sched` showed 7 voluntary context switches in 22 h.

The other two nodes run the same chain (simpledrm, fbcon, dashboard on tty2)
but their VGA keeps decoding, so the same blit costs microseconds. Only
`kubernetes-1` has a second, real GPU for the arbiter to hand VGA to.

Why only from 2026-11-08: the condition needs a **cold** boot, where OVMF
creates the boot framebuffer. The warm boot of 2026-10-26 14:49 (Talos upgrade,
kexec) ran clean for 13 days; the power cut and the host reboot of 2026-11-09
were both cold. The cold boot of 2026-10-09, on Talos 1.13, held one CPU at
13 % `system`, probably the same chain at a slower repaint rate. That last part
is inference.

## Mitigation (2026-11-10 16:18)

The console was switched from tty2 (the dashboard) to tty1 (the kernel log),
which fbcon only repaints when the kernel logs:

```bash
qm sendkey 810 alt-f1        # on pve-1
```

Within one blit, `system` CPU on every vCPU dropped to ~2.5 %. This lasts until
the VM boots again, or until someone presses Alt+F2 in the Proxmox console.

## Permanent fix

Remove the emulated VGA from VM 810. The node has a real GPU, is managed
through `talosctl`, and nothing documented needs its console.

```bash
qm set 810 --vga none        # on pve-1; takes effect on the next start
```

Without a boot framebuffer, `simpledrm`
does not load and the dashboard writes to a dummy console. Cost: the Proxmox
console of VM 810 goes blank.

Verified after the cold boot of 2026-11-10 16:34 (`talosctl shutdown`, then
`qm start 810`; an ACPI `qm shutdown` timed out, since Talos ignores the power
button here):

- `/proc/iomem` has no `BOOTFB`, and `simpledrm` does not load.
- System CPU on the node is 0.26 cores, with no vCPU above 2.2 %.
- Zero WAL fsyncs over 1 s on all three members.
- Jellyfin is back on the iGPU (`gpu.intel.com/i915` allocatable).

Rejected: `talos.dashboard.disabled=1` as a kernel argument. It needs a new
schematic and an upgrade, and still leaves every kernel log line costing a
5-second trapped blit.

## So it does not happen again

Not done yet:

1. **Find out why two hosts on the UPS lost power at 16:37 on 2026-11-08**, and
   `pve-3` the next morning. If these were not deliberate, the UPS did not do
   its job, and that is what exposed this bug: it needed a cold boot. Check
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
   be finished from metrics. `kptr_restrict=2` also hides kernel symbols, so
   the work function was identified from registers, not by name.
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
