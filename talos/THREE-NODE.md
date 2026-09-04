# Three control planes

The cluster is three nodes, one per physical machine, since 2026-09-04:

| Node | Address | Runs on | Carries |
|---|---|---|---|
| `kubernetes-1` | 10.57.57.80 | VM 810 on `pve-1` (Beelink) | etcd, workloads, Iris Xe for transcoding |
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
scheduling stays disabled there; the placement survived the outage.

## What each machine costs you when it dies

| Dies | Result |
|---|---|
| `pve-1` | Quorum holds. Pods reschedule onto `pve-2`. **Jellyfin loses hardware transcoding** — the Iris Xe is only here, and the Nvidia extensions for `pve-2`'s Quadro P2200 were dropped on 2026-09-01. |
| `pve-3` | Nothing. It holds a vote and a replica; both are redundant. |
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

## Longhorn keeps nothing on `pve-1`

Two replicas per volume, on `kubernetes-2` and `kubernetes-3`. Scheduling is
disabled on `kubernetes-1`.

Its pool is a single QLC NVMe with no redundancy underneath — the ZFS mirror
that once justified a single replica belongs to `pve-2`, and the node stopped
living there on 2026-09-01. Measured at 1.27 MB/s sustained, roughly 110 GB a
day, that disk had about three years left while it carried every write in the
cluster. Carrying only the OS and etcd, it has roughly fourteen.

The cost is that every volume read leaves the node. That is the same 1 GbE the
media already crosses by NFS, so it is not a new category of traffic — but it
is a real added latency of a few tenths of a millisecond per operation.

**`kubernetes-3` must not be tainted.** A `NoSchedule` taint there was tried
and reverted on 2026-09-04: Longhorn's replica scheduler skips a tainted node
outright, reporting `no disk candidates found`, and no `taintToleration`
setting changes that — the toleration decides whether Longhorn's pods may run,
not whether the scheduler will place a replica. So the node either holds
replicas or is isolated from workloads, never both. Keep pods off it with
per-workload constraints if it ever matters.

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
