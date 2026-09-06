# Three control planes

The cluster is three nodes, one per physical machine, since 2026-09-04:

| Node | Address | Runs on | Carries |
|---|---|---|---|
| `kubernetes-1` | 10.57.57.80 | VM 810 on `pve-1` (Beelink) | etcd, workloads, a Longhorn replica, Iris Xe for transcoding |
| `kubernetes-2` | 10.57.57.82 | VM 811 on `pve-2` (R730xd) | etcd, workloads, a Longhorn replica |
| `kubernetes-3` | 10.57.57.83 | VM 812 on `pve-3` (OptiPlex) | etcd, a Longhorn replica |

Three etcd votes in three chassis, three power supplies, three motherboards.
Losing any one machine leaves a quorum. That is the whole point, and it is the
first time it has been true here — the three control planes that existed until
August all sat on `pve`, so a single host reboot took every one of them down.

## Drilled, 2026-09-04

`pve-1` powered off cold at 19:40, with no warning to the cluster.

| | |
|---|---|
| etcd | Quorum held on two members. The API stayed reachable through the VIP, which floated to a surviving node |
| Workloads | 61 running pods on the dead node. `kubernetes-2` went 14 → 41, `kubernetes-3` 12 → 15 |
| Volumes | 19 of 23 detached and reattached on their own. The other four belonged to pods that could not schedule |
| Back up | Immich, Radarr, Sonarr, Prowlarr, qBittorrent, Jellyseerr, n8n, Flux and Grafana all 1/1 by 19:47 — **about six minutes** |
| Down | Jellyfin and jellyfin-public, `Pending` on `Insufficient gpu.intel.com/i915`. Expected: the iGPU is only on `pve-1` |
| Recovery | Woken with a magic packet at 19:49, host up in 27 seconds, VM autostarted, node `Ready` and uncordoned by 19:52 |

Two things worth keeping from it. Wake-on-LAN works on `pve-1`
(`b0:41:6f:15:2b:02`), so this whole cycle ran without anyone in the house —
though the `ethtool` setting behind it does not survive a reboot. And Longhorn
did **not** move replicas back onto the QLC when the node returned, because
scheduling was disabled there at the time; the placement survived the outage.
That is no longer the arrangement — see [below](#longhorn-keeps-one-replica-per-node).

## What each machine costs you when it dies

| Dies | Result |
|---|---|
| `pve-1` | Quorum holds. Pods reschedule onto `pve-2`, and its Longhorn replicas are covered by the other two. **Jellyfin loses hardware transcoding** — the Iris Xe is only here, and the Nvidia extensions for `pve-2`'s Quadro P2200 were dropped on 2026-09-01. |
| `pve-3` | Nothing. It holds a vote and a replica; both are redundant, and the two surviving nodes still have a copy of every volume. |
| `pve-2` | Cluster survives, but the media NFS exports, the Garage S3 LXC that Longhorn backs into, and the Nextcloud VM all go with it. Jellyfin and the \*arr stack keep running with no data underneath them. **No amount of Kubernetes HA fixes this** — a twelve-disk SAS array does not replicate to a mini PC. |

## etcd sits on three very different disks

A commit needs two of three members, so the *fastest two* set the pace, not the
slowest. That matters more than the redundancy:

| Member | Disk | fsync |
|---|---|---|
| `kubernetes-3` | Intel D3-S4510, power-loss protection | best in the fleet |
| `kubernetes-2` | `rpool`, mirrored SSD | good |
| `kubernetes-1` | Crucial P3 Plus, QLC, DRAM-less, 34% worn | worst |

While the cluster was one node, every fsync stall on that QLC was a cluster
stall. Now the other two carry commits straight through it. The 2026-08
`EtcdSlowFsyncBurst` problem stops being an outage and becomes a slow member.

## Longhorn keeps one replica per node

Three replicas per volume since 2026-09-06, one on each node.

It ran on two — `kubernetes-2` and `kubernetes-3`, with scheduling disabled on
`kubernetes-1` to keep writes off its QLC NVMe. That was a mistake, and not the
one it looked like. With no third scheduling target, losing either `pve-2` or
`pve-3` left every volume at a single replica **with nowhere to rebuild the
second**. All 23 would have stayed that way until the dead machine physically
came back. The 2026-09-04 drill missed it because it killed `pve-1` — the only
node that held no replicas.

The third copy cost more than predicted. Measured on the host after the
rebuild finished, physical writes on `kubernetes-1`'s NVMe went from
**0.95 to 1.29 MB/s** — 82 to 112 GB a day, **+36%**, taking the disk from
~4.4 years of remaining endurance to **~3.2**.

The prediction was +21%, and the way it failed is worth keeping. All 23 volumes
together write only 72 KB/s (`longhorn_volume_write_throughput`, 24h average),
and that was multiplied by the 2.8x amplification measured for the node's
aggregate traffic. Replica writes are not aggregate traffic: they are small and
random, so against a 16K `volblocksize` each one costs a read-modify-write. The
measured amplification for that traffic alone is closer to **12x** — 0.34 MB/s
of physical writes for 72 KB/s of volume writes.

**Amplification belongs to a traffic pattern, not to a pool.** A single figure
measured across mixed traffic cannot be applied to one new stream.

A local replica also ends the network hop on reads. `kubernetes-1` runs the
most pods in the cluster, and until now every one of their volume reads crossed
the 1 GbE link.

### Do not trust write rates measured inside the VM

An earlier version of this file put the disk's remaining life at "roughly
fourteen" years. It was wrong by about 3x, because it counted what the Talos VM
reported writing rather than what the physical NVMe actually wrote:

| Layer | Rate |
|---|---|
| Inside the VM (`node_disk_written_bytes_total`, sda) | 0.345 MB/s |
| Physical, on `pve-1` (`/proc/diskstats`, nvme1n1) | **0.95 MB/s** |

That is **2.8x** amplification from the zvol (`volblocksize=16K`, `ashift=12`,
`sync=standard`) plus ZFS metadata. Any endurance estimate has to start at the
host, not in the guest. Real numbers, from SMART (34% used at 67.8 TB written):
~4.4 years before the third replica, ~3.2 with it.

The rest of the fleet has no endurance question at all — all four Intel
D3-S4510s (`pve-2`'s `rpool` mirror, `pve-3`'s etcd disk) read 0% wear after
more than 9,000 hours.

**`kubernetes-3` must not be tainted.** A `NoSchedule` taint there was tried
and reverted on 2026-09-04: Longhorn's replica scheduler skips a tainted node
outright, reporting `no disk candidates found`, and no `taintToleration`
setting changes that — the toleration decides whether Longhorn's pods may run,
not whether the scheduler will place a replica. So the node either holds
replicas or is isolated from workloads, never both. Keep pods off it with
per-workload constraints if it ever matters.

## Editing talconfig.yaml changes nothing on its own

The taint came back on 2026-09-04, hours after being removed. Not a Talos bug:
`talconfig.yaml` had been edited and committed, but the node was still running
the machine config generated *before* that edit, and re-applied its taint when
it re-registered during the `pve-1` drill.

It surfaced as `KubeDaemonSetRolloutStuck` and `KubeDaemonSetMisScheduled` —
with `kubernetes-3` tainted again, the DaemonSet controller computed
`desiredNumberScheduled: 2` while three pods were running, so one counted as
misscheduled. Longhorn's existing replicas were unaffected, because a taint
blocks new placement rather than running replicas; the damage would have shown
up only the next time one needed rebuilding there.

Editing the file is two thirds of the job:

```bash
task talos:generate-config
task talos:apply-node IP=10.57.57.83 MODE=auto   # applied without a reboot
```

Nothing compares a node's running config against this repo, the same gap that
let `talenv.yaml` sit six days ahead of the cluster. `nightly-checks.sh` does
exactly this for `pve-2`; the nodes have no equivalent.

## Upgrades are rolling again

`DRAIN=false` is no longer needed. Pods have somewhere to go, so the Longhorn
`instance-manager` PDB that used to burn the whole drain timeout now succeeds.

Upgrade one node at a time and wait for it to rejoin before starting the next.
A failed upgrade stops being a restore and becomes a halt: two healthy members
still hold the cluster while you work out what went wrong on the third.

## What this does not fix

- **The switch.** All three nodes hang off one. It dies, the cluster partitions
  into three isolated members and stops. This is more likely than any single
  server failing.
- **pfSense**, on one XCY X44: gateway, DHCP, Tailscale subnet router.
- **etcd and Longhorn share that same 1 GbE**, and Longhorn v1 has no rebuild
  bandwidth throttle — `Replica Rebuilding Bandwidth Limit` is V2 data engine
  only. `concurrentReplicaRebuildPerNodeLimit: 1` narrows the burst; it does
  not remove it. The safety net is the quorum, not a limit.

Going from one point of failure to three of them removed one. It is worth
doing, and it is not the same as being safe.

Related: [talconfig.yaml](talconfig.yaml) · [DR.md](../DR.md) ·
[longhorn helmrelease](../kubernetes/apps/storage/longhorn/app/helmrelease.yaml)
