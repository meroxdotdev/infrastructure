# Single control plane

The cluster is **one node**: `kubernetes-1` (VM 810, `10.57.57.80`, on
`px-0`/Beelink), control plane and workload host in the same VM. 14 cores,
32 GiB, with the Iris Xe passed through for Jellyfin.

That has been the shape since 2026-09-01. Before it, the single control plane
lived on `pve`/R730xd with a worker on `px-0`; before that, three control
planes on `pve`. Each step removed machinery that was not buying anything.

**Why one and not two.** Two control planes cannot form a quorum — lose either
and the cluster stops, which is strictly worse than one. Three would need a
third fault domain, and there are only two machines. A third VM on `pve` or
`px-0` rebuilds exactly the illusion torn down in August: HA that dies with
the host underneath it.

**So there is no HA, deliberately.** Recovery is a restore, not a failover:
`docs/dr-quickstart.md`, drilled, ~35 minutes. If you want the cluster to
survive either machine going down, it takes a third etcd vote in a third
fault domain plus Longhorn replicas on both — priced out in the 2026-09-01
discussion, not adopted.

**What `pve` still carries:** the media array and its NFS exports, every
backup leg, the Garage S3 LXC that Longhorn backs up into, and the Nextcloud
VM. Losing it costs media and backups, not the cluster.

The sizing math and the exact migration steps lived in
`single-node-migration-log.md`, removed 2026-08-29 once the migration was
done. Git still has it: `git show 9385285:talos/single-node-migration-log.md`.

Related: [talconfig.yaml](talconfig.yaml) · [DR.md](../DR.md) ·
[longhorn helmrelease](../kubernetes/apps/storage/longhorn/app/helmrelease.yaml)

## Ongoing health signals

| Signal | Command | Healthy |
|---|---|---|
| CPU pressure | `kubectl top node` | < 10 of 14 cores |
| Memory pressure | `kubectl top node` | < 34 GiB of 44 |
| etcd fsync | `EtcdSlowFsyncBurst` alert | quiet outside 03:00-03:30 |
| etcd elections | `EtcdLeaderElectionsCreeping` | structurally impossible now |
| Longhorn headroom | `kubectl -n longhorn-system get nodes.longhorn.io` | > 150 GiB free |
| `cluster-storage` | `zpool list cluster-storage` | < 60% |

If `kubectl top node` sits high during an evening Jellyfin transcode, raise
the VM before concluding one node doesn't work — the Beelink has 20 threads
and 62 GiB, of which ARC takes 4 and Proxmox Datacenter Manager 8. Also watch `Pending` pods
(`kubectl get pods -A --field-selector=status.phase=Pending`): the scheduler
binds on `requests`, not usage, so a node can look idle in `top` while a pod
still won't schedule.

Nightly etcd snapshot (the one thing a single member makes strictly worse —
no peer to rebuild from) runs at 03:03 via
[`proxmox/r730xd/scripts/etcd-snapshot.sh`](../proxmox/r730xd/scripts/etcd-snapshot.sh).
Restore: `talosctl bootstrap --recover-from=<snapshot>`, snapshot lives under
`/media/backups/etcd/` and rides the existing restic push to Oracle.

A Talos/Kubernetes upgrade of this node is a full outage of a few minutes
instead of a rolling one — accepted, since a `pve` reboot already took all
three old nodes down simultaneously anyway.

**It also cannot be drained**, which matters because the upgrade task tries to
by default. Longhorn's `instance-manager` PDB is `minAvailable: 1` with zero
allowed disruptions, so with nowhere to move it the eviction never succeeds:
the drain burns the whole timeout and aborts *before* the reboot, leaving the
node cordoned and its workloads on the floor. Use `DRAIN=false`:

```bash
task talos:upgrade-node IP=10.57.57.80 DRAIN=false
```

The default stays `true` because it is correct for a worker, whose pods have
somewhere else to go. There are no workers today.

## Going back

There is nothing to roll back to. VMs 802/804 were deleted in August and VM
800 in September; the node blocks left `talconfig.yaml` on 2026-09-01. Adding
a node is `docs/operations.md` → "Adding a worker node", from scratch.

Git holds every previous shape: `git show 793bf33:talos/talconfig.yaml` for
the two-node version, `git show 9385285:talos/single-node-migration-log.md`
for the original three.
