# Single-node Talos cluster

The cluster runs one control-plane VM: `kubernetes-controlplane-1` (VM 800,
`10.57.57.80`, on `pve`/R730xd). It holds the Quadro P2200 passthrough for
Jellyfin transcoding. This has been the case since 2026-08-17 and is the
intentional, accepted state — not a degraded or temporary one. Nodes 2 and 3
were removed because all three VMs ran on the same physical host anyway, so
the 3-node HA was illusory (one `pve` outage always took down all three) and
cost 3x the Longhorn replicas and etcd raft overhead for a failure mode
(single-VM death) that never happened.

The sizing math and the exact migration steps lived in
`single-node-migration-log.md`, removed 2026-08-29 once the migration was
done. Git still has it: `git show 9385285:talos/single-node-migration-log.md`.

Related: [talconfig.yaml](talconfig.yaml) · [DR.md](../DR.md) ·
[longhorn helmrelease](../kubernetes/apps/storage/longhorn/app/helmrelease.yaml)

## Ongoing health signals

| Signal | Command | Healthy |
|---|---|---|
| CPU pressure | `kubectl top node` | < 7 of 10 cores |
| Memory pressure | `kubectl top node` | < 45 GiB of 64 |
| etcd fsync | `EtcdSlowFsyncBurst` alert | quiet outside 03:00-03:30 |
| etcd elections | `EtcdLeaderElectionsCreeping` | structurally impossible now |
| Longhorn headroom | `kubectl -n longhorn-system get nodes.longhorn.io` | > 150 GiB free |
| `rpool` | `zfs list rpool` | < 40% |

If `kubectl top node` sits above 7 of 10 cores during an evening Jellyfin
transcode, raise to 12 before concluding one node doesn't work — the host
has 16 threads and 153 GB free. Also watch `Pending` pods
(`kubectl get pods -A --field-selector=status.phase=Pending`): the scheduler
binds on `requests`, not usage, so a node can look idle in `top` while a pod
still won't schedule.

Nightly etcd snapshot (the one thing single-node made strictly worse — no
peer to rebuild from) runs at 03:03 via
[`proxmox/r730xd/scripts/etcd-snapshot.sh`](../proxmox/r730xd/scripts/etcd-snapshot.sh).
Restore: `talosctl bootstrap --recover-from=<snapshot>`, snapshot lives under
`/media/backups/etcd/` and rides the existing restic push to Oracle.

A Talos/Kubernetes upgrade is now a full outage of a few minutes instead of
a rolling one — accepted, since a `pve` reboot already took all three old
nodes down simultaneously anyway.

## Rollback to 3 nodes

No data loss, ~30 minutes (most of it Longhorn copying ~100 GiB back onto
the returning nodes). Talos nodes are disposable and declarative, so this is
re-provisioning from git, not restoring anything.

```bash
# 1. Put nodes 2 and 3 back in git
#    - uncomment both blocks in talos/talconfig.yaml
#    - revert the Longhorn replica counts (defaultReplicaCount "3",
#      defaultClassReplicaCount 3, csi.* 3, longhornUI 3)
#    - optionally re-add spegel (removed 2026-08-17, kubernetes-controlplane-1
#      commit d3a53fb^ has the last copy of its manifests) - peer-to-peer
#      image caching between nodes, worth having again with 3 real ones.
git revert <the single-node migration commit> && git push

# 2. Recreate VMs 802/804 — they were deleted, not just stopped, see
#    "VM recreation spec" below. Then boot to maintenance mode:
ssh root@10.57.57.250 'qm start 802; qm start 804'

# 3. Regenerate and apply — they join as fresh control-plane members
task talos:generate-config
task talos:apply-node IP=10.57.57.82 MODE=auto
task talos:apply-node IP=10.57.57.84 MODE=auto

# 4. Let Flux restore the Longhorn settings, then re-expand the volumes
flux reconcile kustomization cluster-apps --with-source
for n in kubernetes-controlplane-2 kubernetes-controlplane-3; do
  kubectl -n longhorn-system patch nodes.longhorn.io $n --type=merge \
    -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}'
done
kubectl -n longhorn-system get volumes.longhorn.io -o name | while read -r v; do
  kubectl -n longhorn-system patch "$v" --type=merge -p '{"spec":{"numberOfReplicas":3}}'
done

# 5. Watch the rebuild
watch -n30 'kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness'
```

### VM recreation spec

VMs 804 and 802 were deleted (not just stopped) during the migration, so
rollback recreates them from this captured config:

```bash
# Node 2 — the exact config that was running
qm create 802 --name kubernetes-controlplane-2 --tags k8s \
  --cores 4 --sockets 1 --cpu host --memory 49152 --numa 0 \
  --ostype l26 --scsihw virtio-scsi-single --boot 'order=scsi0;net0' --onboot 1 \
  --net0 'virtio=BC:24:11:43:4E:63,bridge=vmbr0,firewall=1' \
  --scsi0 'local-zfs:400,format=raw,iothread=1,ssd=1'

# Node 3 — same shape; only name, vmid and MAC differ
qm create 804 --name kubernetes-controlplane-3 --tags k8s \
  --cores 4 --sockets 1 --cpu host --memory 49152 --numa 0 \
  --ostype l26 --scsihw virtio-scsi-single --boot 'order=scsi0;net0' --onboot 1 \
  --net0 'virtio=BC:24:11:96:87:40,bridge=vmbr0,firewall=1' \
  --scsi0 'local-zfs:400,format=raw,iothread=1,ssd=1'
```

⚠️ **`talconfig.yaml` and the live MAC of node 2 disagree.** The file
declares `bc:24:11:a5:4b:9e` for `kubernetes-controlplane-2`; the VM that
was actually running used `BC:24:11:43:4E:63`. Node 1 matches its file
correctly, so this is node-2-only drift.
`networkInterfaces[].deviceSelector.hardwareAddr` picks the NIC by MAC:
recreate the VM with the file's MAC and nothing matches, so the node boots
with no address. Either create the VM with `bc:24:11:a5:4b:9e` to match the
file, or fix the file first — don't assume they agree. Node 3's MAC was
never independently verified against a live VM.
