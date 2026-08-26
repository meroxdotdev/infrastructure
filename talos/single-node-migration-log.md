# Single-node migration — execution log (2026-08-17)

Forensic record of how the cluster went from 3 control-plane VMs to 1. The
migration is done; this is the "how it was actually done and why" record, not
an operational doc. For current state and how to roll back, see
[SINGLE-NODE.md](SINGLE-NODE.md).

## Why, in detail

| | Now (3 VM) | After (1 VM) |
|---|---|---|
| Allocated | 12 vCPU · 144 GB RAM · 1200 G | 10 vCPU · 64 GB RAM · 400 G |
| Peak used (7d) | 6.44 cores · 17.0 GiB | ~5.0 cores · ~12.7 GiB |
| `rpool` consumed | 384 G | ~130-150 G |
| Longhorn replicas | 3 | 1 |
| etcd members | 3 (raft, elections) | 1 (no raft) |

Three reasons, in order of weight:

1. **The HA was illusory.** All three VMs ran on one physical host. On 7-9
   August `pve` was down 52 hours and all three nodes went with it. A 3-node
   cluster protects against single-VM death — a failure mode that never
   occurred — and cost 3x of everything against the one that did.
2. **Three Longhorn replicas on a ZFS mirror was six physical copies.**
   `rpool` is 2x mirror across 4 SSDs. Longhorn triplicates, ZFS mirrors each
   copy. Dropping to one replica still leaves two physical copies; real disk
   redundancy comes from the mirror and didn't change.
3. **No raft, no elections.** `EtcdLeaderElectionsCreeping` became
   structurally impossible.

**Survivor: `kubernetes-controlplane-1` (VM 800, 10.57.57.80).** It holds the
Quadro P2200 passthrough, so Jellyfin transcoding was unaffected.

### Sizing — why 10 vCPU / 64 GB

One node uses less than the sum of three, because per-node overhead stops
being triplicated. Per-node overhead was ~0.70 cores and ~3.1 GiB — etcd,
cilium, longhorn-manager, instance-manager, engine-image, promtail,
node-exporter, spegel, and the apiserver/scheduler/controller-manager
triplet. Two of those three copies disappear.

The binding constraint was `requests`, not usage: the scheduler places pods
by request, and the cluster asked for 6309m CPU and ~35 GiB across three
nodes. Removing the double-counted DaemonSet requests left roughly 4.9 cores
and 28 GiB a single node had to satisfy.

So: 10 vCPU (peak 5.0, requests 4.9, ~2x headroom for Jellyfin transcode
spikes) and 64 GB (requests ~28 GiB, peak ~12.7 GiB — generous because the
host has 153 GB free and Immich/Prometheus grow). Going past 10 vCPU was
counterproductive: the host is 8C/16T and over-allocating vCPU adds KVM
scheduling contention rather than capacity.

## Three things that bit during the migration

Relevant again only if this shrink is ever repeated (e.g. after a rollback
to 3, shrinking back to 1):

1. **Longhorn ships 3-replica deployments with pod anti-affinity.**
   `csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter` and
   `longhorn-ui` all run `replicas: 3` with anti-affinity. On one node, two
   of each sit `Pending` forever — must be lowered in the HelmRelease.
2. **`instance-manager-*` PDBs allow 0 disruptions.** `kubectl drain` on the
   nodes being removed will hang. The Longhorn *eviction* flow is the
   correct tool and removes the PDBs as replicas leave. Do not force-drain.
3. **Flux owns Longhorn's settings.** `storageMinimalAvailablePercentage`
   lives in
   [helmrelease.yaml](../kubernetes/apps/storage/longhorn/app/helmrelease.yaml),
   so a `kubectl patch` is reverted on the next reconcile — every setting
   change goes through git.

## Phase-by-phase execution

### Phase A — safety net and resize, while 3 nodes still covered it

```bash
# A1. Confirm last night's Longhorn backup completed
kubectl -n longhorn-system get backups.longhorn.io \
  -o custom-columns=NAME:.metadata.name,VOL:.status.volumeName,STATE:.status.state,AT:.status.backupCreatedAt \
  | sort -k4 | tail -12

# A2. ZFS snapshots of all three node disks — Tier-1 rollback
for v in 800 802 804; do
  ssh root@10.57.57.250 "zfs snapshot rpool/data/vm-${v}-disk-0@pre-single-node"
done
ssh root@10.57.57.250 'zfs list -t snapshot -o name,used | grep pre-single-node'

# A3. Resize VM 800. Requires a stop/start; nodes 2 and 3 carry the cluster.
ssh root@10.57.57.250 'qm shutdown 800 && sleep 45 && qm set 800 --cores 10 --memory 65536 && qm start 800'

# A4. Wait for it back, then confirm the GPU came back with it
kubectl wait --for=condition=Ready node/kubernetes-controlplane-1 --timeout=10m
kubectl get node kubernetes-controlplane-1 -o jsonpath='{.status.allocatable}' | jq
kubectl -n kube-system logs -l app.kubernetes.io/name=nvidia-device-plugin --tail=20
```

Gate: all three nodes `Ready`, every Longhorn volume `healthy`, nvidia
plugin registered `nvidia.com/gpu` on node 1.

### Phase B — git changes

**`kubernetes/apps/storage/longhorn/app/helmrelease.yaml`:**

```yaml
    defaultSettings:
      defaultReplicaCount: "1"                    # was "3"
      storageMinimalAvailablePercentage: "25"     # was "1" — see audit 2026-08-17
      replicaAutoBalance: "false"                 # was "true" — meaningless on one node
      defaultDataLocality: "disabled"             # was best-effort — same reason

    persistence:
      defaultClassReplicaCount: 1                 # was 3

    longhornUI:
      replicas: 1                                 # was 3

    csi:                                          # new block
      attacherReplicaCount: 1
      provisionerReplicaCount: 1
      resizerReplicaCount: 1
      snapshotterReplicaCount: 1
```

**`talos/talconfig.yaml`** — commented out nodes 2 and 3, kept in the file
(so the pinned MAC addresses `bc:24:11:a5:4b:9e` / `bc:24:11:96:87:40` stay
around for a cheap Tier-2 rollback), left `vip: 10.57.57.88` on node 1 — the
cluster endpoint stayed `https://10.57.57.88:6443`, no kubeconfig/cert churn.

```bash
git add -A && git commit -m "feat(talos): shrink to a single control-plane node" && git push
flux reconcile kustomization cluster-apps --with-source
```

Gate: `kubectl -n longhorn-system get deploy` shows `1/1` for every `csi-*`
and `longhorn-ui`. No `Pending` pods anywhere.

### Phase C — consolidate every replica onto node 1

The step where data could be lost if rushed. Nothing was removed until node
1 held a complete, healthy copy of all 20 volumes.

```bash
# C1. Stop new replicas landing on the nodes that are leaving
for n in kubernetes-controlplane-2 kubernetes-controlplane-3; do
  kubectl -n longhorn-system patch nodes.longhorn.io $n --type=merge \
    -p '{"spec":{"allowScheduling":false}}'
done

# C2. Existing volumes are NOT affected by the StorageClass change — each one
#     carries its own numberOfReplicas and must be patched.
kubectl -n longhorn-system get volumes.longhorn.io -o name | while read -r v; do
  kubectl -n longhorn-system patch "$v" --type=merge -p '{"spec":{"numberOfReplicas":1}}'
done

# C3. Force any surviving replica off nodes 2 and 3
for n in kubernetes-controlplane-2 kubernetes-controlplane-3; do
  kubectl -n longhorn-system patch nodes.longhorn.io $n --type=merge \
    -p '{"spec":{"evictionRequested":true}}'
done

# C4. Watch until every replica sits on node 1.
watch -n10 'kubectl -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState'
```

Gate — all three had to hold:

```bash
kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r \
  '.items[] | "\(.metadata.name) \(.status.robustness) r=\(.spec.numberOfReplicas) \(.status.state)"'

# Filter on currentState=="running", not on nodeID alone — reducing the
# replica count leaves stopped replica objects behind, some with an empty
# nodeID, and a naive "nodeID != node-1" check counts those as stragglers.
# Observed: 6 "stuck", of which 5 were empty-node debris and the 6th was a
# stopped object on node 3. All 20 running replicas were already home.
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r \
  '[.items[] | select(.status.currentState=="running" and .spec.nodeID != "kubernetes-controlplane-1")] | length'   # must print 0

kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r \
  '.items[] | select(.status.currentState=="running") | .spec.nodeID' | sort | uniq -c

kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r \
  '[.items[] | select(.status.robustness != "healthy")] | length'               # must print 0
```

### Phase D — remove nodes 3 and 2

One at a time, verifying etcd between them (the intermediate 2-member state
has quorum 2 — both must stay up).

```bash
# D1. Node 3 out
kubectl cordon kubernetes-controlplane-3
kubectl drain kubernetes-controlplane-3 --ignore-daemonsets --delete-emptydir-data --timeout=5m
talosctl -n 10.57.57.84 reset --graceful=true --reboot   # leaves etcd cleanly
kubectl delete node kubernetes-controlplane-3

# D2. Confirm 2 healthy members BEFORE touching node 2
talosctl -n 10.57.57.80 etcd members
talosctl -n 10.57.57.80 service etcd status

# D3. Node 2 out
kubectl cordon kubernetes-controlplane-2
kubectl drain kubernetes-controlplane-2 --ignore-daemonsets --delete-emptydir-data --timeout=5m
talosctl -n 10.57.57.82 reset --graceful=true --reboot
kubectl delete node kubernetes-controlplane-2

# D4. Stop the VMs — do NOT destroy them, Tier 2 rollback reuses the definitions
ssh root@10.57.57.250 'qm stop 802; qm stop 804'
```

If a drain hangs on `instance-manager-*`, Phase C did not finish — go back
and re-check its gate rather than forcing it.

### Phase E — verify

```bash
kubectl get nodes -o wide                                    # exactly 1, Ready
talosctl -n 10.57.57.80 etcd members                         # exactly 1
kubectl get pods -A | grep -vE 'Running|Completed'           # empty
flux get kustomizations -A | grep -v True                    # empty (header only)
kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r \
  '[.items[] | select(.status.robustness != "healthy")] | length'   # 0

ssh root@10.57.57.250 'zfs list rpool/data; zpool list rpool'

curl -sI https://photos.k8s.merox.dev | head -1
curl -sI https://jellyfin.merox.dev   | head -1
```

Then confirmed over the first nightly cycle: 23:50 Longhorn recurring backup
reached `Completed` on every volume, 03:10 restic push to Oracle succeeded,
certificate renewal still worked.

## Tier 1 rollback (was only useful during the migration itself)

Reverts everything including data written since the Phase A2 ZFS snapshot —
those snapshots are long gone now, so this tier is history, not a usable
path any more. Kept for the record:

```bash
ssh root@10.57.57.250 'qm stop 800; qm stop 802; qm stop 804'
for v in 800 802 804; do
  ssh root@10.57.57.250 "zfs rollback -r rpool/data/vm-${v}-disk-0@pre-single-node"
done
ssh root@10.57.57.250 'qm set 800 --cores 4 --memory 49152; qm start 800; qm start 802; qm start 804'
git revert <the Phase B commit> && git push
```

## Nightly etcd snapshot — why 03:03 and not 23:45

The one thing single-node genuinely made worse: with three members a
corrupted or lost etcd is rebuilt from its peers; with one there is no peer.
[`proxmox/r730xd/scripts/etcd-snapshot.sh`](../proxmox/r730xd/scripts/etcd-snapshot.sh)
(cron `3 3 * * *`, listed in
[proxmox/r730xd/README.md's nightly schedule](../proxmox/r730xd/README.md#nightly-schedule))
was **not** run at 23:45 as originally proposed here — that was tried first
and produced 53 slow fsyncs and a failed Flux Kustomization the same night:
writing the ~186 MB snapshot to `media` wakes the SAS pool, and outside the
compact nightly window that wake stalls etcd's own fsyncs on the SSDs behind
it — the job caused the exact outage it exists to prevent. Inside the
03:00-03:30 window the disks are already spinning for other jobs, so it's
free.

## Decision record

**Rejected: full teardown to a single Docker VM.** Every incident found in
the 2026-08-17 audit came from the imperative layer — cron, shell, hardware,
power — and none from Kubernetes, which held 39 kustomizations and 32
HelmReleases with zero drift and zero OOMKills. Collapsing to Docker would
delete the layer that works and keep the layer that breaks.

**Rejected: clean rebuild via [DR.md](../DR.md).** It is the drilled path
and would have re-validated DR, but it forces the Immich and Jellyfin
post-restore manual steps and moves ~100 GiB through S3 for no benefit.
Shrinking in place kept the data where it was.

**Rejected: deleting nodes 2 and 3 from `talconfig.yaml`.** Commenting them
out keeps git truthful about the running state while leaving the pinned MAC
addresses in place, which is the whole reason Tier-2 rollback is ~20
minutes.
