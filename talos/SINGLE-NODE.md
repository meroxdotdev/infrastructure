# Shrink the cluster to one node — and back

> **Status: PLAN. Nothing below has been executed.** Written 2026-08-17 against
> the live cluster. Every number was read off the host, not estimated.

Reduces the Talos cluster from 3 control-plane VMs to 1, keeping Flux, every
manifest and the whole GitOps flow untouched. Designed so the rollback to 3 is
a git revert plus two `task` commands, with **no data loss**, for as long as
you want to think about it.

Related: [talconfig.yaml](talconfig.yaml) · [DR.md](../DR.md) ·
[longhorn helmrelease](../kubernetes/apps/storage/longhorn/app/helmrelease.yaml)

---

## 0. Why

| | Now (3 VM) | After (1 VM) |
|---|---|---|
| Allocated | 12 vCPU · 144 GB RAM · 1200 G | 10 vCPU · 64 GB RAM · 400 G |
| Peak used (7d) | 6.44 cores · 17.0 GiB | **~5.0 cores · ~12.7 GiB** |
| `rpool` consumed | 384 G | ~130–150 G |
| Longhorn replicas | 3 | 1 |
| etcd members | 3 (raft, elections) | 1 (no raft) |

Three reasons, in order of weight:

1. **The HA is illusory.** All three VMs run on one physical host. On 7–9 August
   `pve` was down 52 hours and all three nodes went with it. A 3-node cluster
   protects against single-VM death — a failure mode that has never occurred
   here — and costs 3× of everything against the one that did.
2. **Three Longhorn replicas on a ZFS mirror is six physical copies.** `rpool`
   is 2× mirror across 4 SSDs. Longhorn triplicates, ZFS mirrors each copy.
   Dropping to one replica still leaves **two physical copies**; real disk
   redundancy comes from the mirror and does not change.
3. **No raft, no elections.** `EtcdLeaderElectionsCreeping` becomes structurally
   impossible. Slow fsync still costs local latency, but quorum loss and
   cross-node amplification disappear.

**Survivor: `kubernetes-controlplane-1` (VM 800, 10.57.57.80).** It holds the
Quadro P2200 passthrough and the `nvidia.com/gpu` labels, so Jellyfin transcoding
is unaffected.

### Sizing — why 10 vCPU / 64 GB

One node uses **less than the sum of three**, because per-node overhead stops
being triplicated. Measured over 7 days:

| | 3 nodes | 1 node |
|---|---|---|
| CPU, peak | 6.44 cores | **~5.0 cores** |
| RAM, peak | 17.0 GiB containers | **~10.8 GiB** + ~1.9 GiB Talos OS |

Per-node overhead is ~0.70 cores and ~3.1 GiB — etcd, cilium, longhorn-manager,
instance-manager, engine-image, promtail, node-exporter, spegel, and the
apiserver/scheduler/controller-manager triplet. Two of those three copies
disappear.

**The binding constraint is `requests`, not usage.** The scheduler places pods
by request, and the cluster asks for 6309m CPU and ~35 GiB across three nodes.
Removing the double-counted DaemonSet requests leaves roughly **4.9 cores and
28 GiB that a single node must be able to satisfy** — below that, pods sit
`Pending` on an otherwise idle node.

So: **10 vCPU** (peak 5.0, requests 4.9, ~2× headroom for Jellyfin transcode
spikes) and **64 GB** (requests ~28 GiB, peak ~12.7 GiB — generous because the
host has 153 GB free and Immich/Prometheus grow).

Going much past 10 vCPU is counterproductive: the host is 8C/16T, and
over-allocating vCPU adds KVM scheduling contention rather than capacity. Ten
still leaves 6 threads for `pve` itself, the Home Assistant VM and the Garage
LXC — and is *less* oversubscribed than the 12 vCPU spread across three VMs
today.

---

## 1. Three things that will bite if skipped

Found while verifying, not theoretical:

**1. Longhorn ships 3-replica deployments with pod anti-affinity.**
`csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter` and
`longhorn-ui` all run `replicas: 3` with anti-affinity. On one node, two of each
sit `Pending` forever. Must be lowered in the HelmRelease — §3.

**2. `instance-manager-*` PDBs allow 0 disruptions.**
`kubectl drain` on nodes 2 and 3 will hang. The Longhorn *eviction* flow is the
correct tool and removes the PDBs as replicas leave — §4. Do not force-drain.

**3. Flux owns Longhorn's settings.**
`storageMinimalAvailablePercentage` lives in
[helmrelease.yaml](../kubernetes/apps/storage/longhorn/app/helmrelease.yaml),
so a `kubectl patch` is reverted on the next reconcile. **Every setting change
here goes through git.** (This corrects the ad-hoc patch suggested earlier.)

---

## 2. Phase A — safety net and resize, while 3 nodes still cover you

Do the reboot first, while HA is real.

```bash
# A1. Confirm last night's Longhorn backup completed — this is the floor
#     under everything below. Do not proceed if it did not.
kubectl -n longhorn-system get backups.longhorn.io \
  -o custom-columns=NAME:.metadata.name,VOL:.status.volumeName,STATE:.status.state,AT:.status.backupCreatedAt \
  | sort -k4 | tail -12

# A2. ZFS snapshots of all three node disks — Tier-1 rollback, see §7.
#     Instant and near-free on rpool.
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

**Gate A — do not continue unless:** all three nodes `Ready`, every Longhorn
volume `healthy`, and the nvidia plugin registered `nvidia.com/gpu` on node 1.

---

## 3. Phase B — git changes

One commit, so the rollback is one revert.

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

    csi:                                          # new block — §1 gotcha 1
      attacherReplicaCount: 1
      provisionerReplicaCount: 1
      resizerReplicaCount: 1
      snapshotterReplicaCount: 1
```

**`talos/talconfig.yaml`** — comment out nodes 2 and 3, keep them in the file:

```yaml
  # --- SINGLE-NODE 2026-08-17 · uncomment both blocks to roll back to 3 ---
  # - hostname: "kubernetes-controlplane-2"
  #   ...
  # - hostname: "kubernetes-controlplane-3"
  #   ...
```

Keeping them commented rather than deleted is what makes §7 Tier 2 cheap: the
MAC addresses (`bc:24:11:a5:4b:9e`, `bc:24:11:96:87:40`) are pinned there and
must match the VMs on rollback.

Leave the `vip: 10.57.57.88` on node 1 — the cluster endpoint stays
`https://10.57.57.88:6443`, so no kubeconfig or cert SAN churn. A Talos VIP on a
single member is the sole leader and works normally.

```bash
git add -A && git commit -m "feat(talos): shrink to a single control-plane node" && git push
flux reconcile kustomization cluster-apps --with-source
```

**Gate B:** `kubectl -n longhorn-system get deploy` shows `1/1` for every
`csi-*` and `longhorn-ui`. No `Pending` pods anywhere.

---

## 4. Phase C — consolidate every replica onto node 1

**This is the step where data can be lost if rushed.** Nothing is removed until
node 1 holds a complete, healthy copy of all 20 volumes.

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

# C4. Watch until every replica sits on node 1. Re-run until the only
#     node column value is kubernetes-controlplane-1.
watch -n10 'kubectl -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState'
```

**Gate C — all three must hold:**

```bash
# every volume healthy, 1 replica, attached
kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r \
  '.items[] | "\(.metadata.name) \(.status.robustness) r=\(.spec.numberOfReplicas) \(.status.state)"'

# zero RUNNING replicas left on nodes 2 or 3.
#
# Filter on currentState=="running", not on nodeID alone. Reducing the replica
# count leaves stopped replica objects behind, some with an empty nodeID, and a
# naive "nodeID != node-1" check counts those as stragglers — it reports a stall
# that is not happening. Observed 2026-08-17: 6 "stuck", of which 5 were empty-
# node debris and the 6th was a stopped object on node 3. All 20 running
# replicas were already home.
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r \
  '[.items[] | select(.status.currentState=="running" and .spec.nodeID != "kubernetes-controlplane-1")] | length'   # must print 0

# and all 20 running replicas accounted for on node 1
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r \
  '.items[] | select(.status.currentState=="running") | .spec.nodeID' | sort | uniq -c

# nothing degraded
kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r \
  '[.items[] | select(.status.robustness != "healthy")] | length'               # must print 0
```

Do not proceed on anything other than `healthy` / `0` / `0`.

---

## 5. Phase D — remove nodes 3 and 2

One at a time, verifying etcd between them. The intermediate 2-member state has
quorum 2 — both must stay up — so do not pause in the middle.

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

# D4. Stop the VMs — do NOT destroy them, §7 Tier 2 reuses the definitions
ssh root@10.57.57.250 'qm stop 802; qm stop 804'
```

If a drain hangs on `instance-manager-*`, Phase C did not finish. Go back and
re-check Gate C rather than forcing it.

---

## 6. Phase E — verify

```bash
kubectl get nodes -o wide                                    # exactly 1, Ready
talosctl -n 10.57.57.80 etcd members                         # exactly 1
kubectl get pods -A | grep -vE 'Running|Completed'           # empty
flux get kustomizations -A | grep -v True                    # empty (header only)
kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r \
  '[.items[] | select(.status.robustness != "healthy")] | length'   # 0

# the point of the exercise
ssh root@10.57.57.250 'zfs list rpool/data; zpool list rpool'

# services actually serving
curl -sI https://photos.k8s.merox.dev | head -1
curl -sI https://jellyfin.merox.dev   | head -1
```

Then confirm the first nightly cycle after the change:

- **23:50** — Longhorn recurring backup fires and every volume reaches `Completed`
- **03:10** — restic push to Oracle succeeds
- Certificate renewal still works (next: wildcard renews ~18 Aug 14:50)

---

## 7. Rollback

Two tiers, deliberately different in cost and reach.

### Tier 1 — during the migration (minutes, loses recent writes)

Only useful before Phase D completes, while the ZFS snapshots from A2 are still
close in time. Reverts everything, including data written since the snapshot.

```bash
ssh root@10.57.57.250 'qm stop 800; qm stop 802; qm stop 804'
for v in 800 802 804; do
  ssh root@10.57.57.250 "zfs rollback -r rpool/data/vm-${v}-disk-0@pre-single-node"
done
ssh root@10.57.57.250 'qm set 800 --cores 4 --memory 49152; qm start 800; qm start 802; qm start 804'
git revert <the Phase B commit> && git push
```

### Tier 2 — days later (no data loss) ← the one you asked for

Talos nodes are disposable and declarative, so going back to 3 is re-provisioning
from git, not restoring anything. Longhorn rebuilds the extra replicas by itself.

```bash
# 1. Put nodes 2 and 3 back in git
#    - uncomment both blocks in talos/talconfig.yaml
#    - revert the Longhorn replica counts (defaultReplicaCount "3",
#      defaultClassReplicaCount 3, csi.* 3, longhornUI 3)
git revert <the Phase B commit> && git push

# 2. Wipe and boot the two VMs (disks are stale etcd members — must start clean)
ssh root@10.57.57.250 'qm start 802; qm start 804'   # boot to maintenance mode

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

# 5. Watch the rebuild — expect ~100 GiB of copying
watch -n30 'kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness'
```

Takes ~30 min, most of it Longhorn copying. Nothing is restored from backup and
nothing is lost, because node 1 held the live data the whole time.

### VM recreation spec — needed because the VMs were deleted

VMs 804 and 802 were removed during the 2026-08-17 migration, so Tier 2 must
recreate them rather than just start them. Captured from the live host before
deletion:

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

⚠️ **`talconfig.yaml` and the live MAC of node 2 disagree.** The file declares
`bc:24:11:a5:4b:9e` for `kubernetes-controlplane-2`; the VM that was actually
running used `BC:24:11:43:4E:63`. Node 1 matches its file correctly, so this is
node-2-only drift — most likely left over from the 2026-08-15 px-0 DR test,
where VMs 810/811/812 were built with "MAC/IP identice".

It matters because `networkInterfaces[].deviceSelector.hardwareAddr` picks the
NIC by MAC: recreate the VM with the file's MAC and nothing matches, so the node
boots with no address. On rollback, either create the VM with
`bc:24:11:a5:4b:9e` to match the file, or fix the file — but do not assume they
agree. Node 3's MAC was never verified against a live VM and is taken from the
file alone.

---

## 7b. Prerequisite: nightly etcd snapshots

**This is the one thing single-node genuinely makes worse, and it is not
currently covered — there are no etcd snapshots anywhere in the repo or in
`pve`'s crontab.**

With three members a corrupted or lost etcd is rebuilt from its peers. With one
there is no peer. Most of the state is reconstructible — Flux rebuilds every
workload from git, secrets are SOPS-encrypted in git, PVC data is in the
Longhorn backups — so the worst case is a [DR.md](../DR.md) rebuild, ~35 min and
drilled. A snapshot turns that into a ~5 minute restore, and costs ~10 seconds a
night.

Add to `pve`'s crontab, before Phase D:

```bash
# 45 23 * * *  — ahead of the 23:50 Longhorn backup
talosctl -n 10.57.57.80 etcd snapshot /media/backups/etcd/etcd-$(date +\%F).db
```

Point it at `/media/backups/etcd/`, which the existing restic push to Oracle
already sweeps up. Prune by name, not `find -mtime` — the same rsync mtime trap
documented in the Nextcloud design applies here.

Restore path: `talosctl bootstrap --recover-from=<snapshot>`.

---

## 8. What to watch over the next days

The trial is about whether one node is *sustainable*, not whether it boots.

| Signal | Command | Healthy |
|---|---|---|
| CPU pressure | `kubectl top node` | < 7 of 10 cores |
| Memory pressure | `kubectl top node` | < 45 GiB of 64 |
| etcd fsync | `EtcdSlowFsyncBurst` alert | quiet outside 03:00–03:30 |
| etcd elections | `EtcdLeaderElectionsCreeping` | **structurally impossible now** |
| Longhorn headroom | `kubectl -n longhorn-system get nodes.longhorn.io` | > 150 GiB free |
| `rpool` | `zfs list rpool` | < 40% |

The honest failure mode to watch for is **CPU**. The 7-day peak was 6.44 cores
across three nodes, which projects to ~5.0 on one — but that peak is an average
over a 5-minute window, and a Jellyfin transcode start is burstier than that. If
`kubectl top node` sits above 7 of 10 cores during an evening transcode, raise
to 12 before concluding that one node does not work; the host has 16 threads and
153 GB free.

Watch `Pending` pods too, and for a different reason: that is the `requests`
ceiling, not the usage one, and it appears as pods that will not schedule on a
node showing plenty of idle CPU.

```bash
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe node kubernetes-controlplane-1 | grep -A8 'Allocated resources'
```

The second is **upgrade downtime**: a Talos or Kubernetes upgrade is now a full
outage of a few minutes instead of a rolling one. Given that a `pve` reboot
already took all three nodes down simultaneously, this changes less than it
sounds.

---

## 9. Decision record

**Rejected: full teardown to a single Docker VM.** Every incident found in the
2026-08-17 audit came from the imperative layer — cron, shell, hardware, power —
and none from Kubernetes, which held 39 kustomizations and 32 HelmReleases with
zero drift and zero OOMKills. Collapsing to Docker would delete the layer that
works and keep the layer that breaks.

**Rejected: clean rebuild via [DR.md](../DR.md).** It is the drilled path and
would have re-validated DR, but it forces the Immich and Jellyfin post-restore
manual steps and moves ~100 GiB through S3 for no benefit. Shrinking in place
keeps the data where it is.

**Rejected: deleting nodes 2 and 3 from `talconfig.yaml`.** Commenting them out
keeps git truthful about the running state while leaving the pinned MAC
addresses in place, which is the whole reason Tier-2 rollback is 20 minutes.
