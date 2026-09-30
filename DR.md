# Disaster Recovery Runbook

Restore the full K8s cluster from Longhorn S3 backups onto fresh Talos nodes.

- **You need:** `age.key`, `talos/talsecret.sops.yaml` (or a full
  re-bootstrap), access to Proxmox.
- **In a hurry:** [`docs/dr-quickstart.md`](docs/dr-quickstart.md) — same
  procedure, commands only.
- **Rebuilding a host instead of the cluster:**
  [pve-2](proxmox/pve-2/REINSTALL.md) · [pfSense](pfsense/REINSTALL.md)

**Tested end-to-end:** 2026-08-29 on **pve-1**, a different physical host —
71 min of prod downtime, prod VM stopped and restarted clean afterward.
Previously 2026-08-03 on pve-2/R730xd.

## Which host to target

Three nodes since 2026-09-04, one per host: VM 810 on `pve-1`, 811 on `pve-2`,
812 on `pve-3`. Losing one leaves a quorum, so a single dead host is a
reschedule, not a DR event. This runbook is for losing the cluster.

| Target | Use it to answer | Cost |
|---|---|---|
| `pve-2` (R730xd) | "the cluster is gone, rebuild it" | None. 251 GB RAM, DR VMIDs start at 820 so they cannot collide |
| `pve-1` (Beelink) | "pve-1 died, can we recover onto it after a rebuild?" | The live node here stops first. Whole homelab down for the drill |

**Sizing:** a DR VM that carries the whole workload set needs
`vm_memory_mb = 45056`, `vm_cores = 14`. 32 GiB leaves pods `Pending` on
`Insufficient memory` against 38 GiB of requests.

**Replica count is derived, not fixed.** `restore-volume` reads
`kubectl get nodes` and caps at 3, so a full three-node restore gets 3 and a
partial rebuild gets what exists. Do not hardcode it.

**What no drill here tests:** hardware transcoding. Jellyfin requests
`gpu.intel.com/i915`, advertised only by a node with the Iris Xe passed through.
On a DR VM without it, it stays `Pending` by design.

**Not part of DR at all:** nothing here is public. The Frankfurt edge was
deleted on 2026-09-08 along with the Jellyfin instance it served —
[what it was and the two lessons kept](docs/jellyfin-public-exposure.md).

---

## Why the restore looks the way it does

Longhorn's native path — a CSI `VolumeSnapshot` with `type: bak` plus a PVC
`dataSource` — cannot restore into a rebuilt cluster. It verifies the source
volume before provisioning, and after a full loss that volume is gone:
`failed to verify data source: volume.longhorn.io ... not found`.
[longhorn/longhorn#4083](https://github.com/longhorn/longhorn/issues/4083)
is closed as **wontfix**.

So this repo restores by creating Longhorn `Volume` CRs with `fromBackup`
and binding them through static PVs with `claimRef` in
`kubernetes/apps/storage/restore-pvs/pvs.yaml`. That is deliberate and
correct for full-cluster DR, not a workaround — do not "simplify" it into
VolumeSnapshots.

The cost of that design is bookkeeping: a volume must be labelled for the
nightly job, listed in `restore-all-volumes`, and given a PV in `pvs.yaml`.
Drift between those three silently discards data — it cost the entire Immich
photo library. All three are now cross-checked automatically:
`dr-preflight.sh` compares labels against the restore list,
`unbind-premature-dynamic-pvcs` derives its work from `pvs.yaml`, and
`dr-verify.sh` derives its expected volume count from the restore task.

## Phase 1 — Provision DR nodes

> **No prerequisite edits.** `talos/terraform/terraform.tfvars` carries one
> MAC, so DR provisions one node — deliberately: one node brings the workloads
> back, and a three-node restore needs three hosts you may not have
> ([docs/dr-quickstart.md](docs/dr-quickstart.md)). `talos/talconfig.yaml`
> declares all three, because that is what prod runs since 2026-09-04. The two
> are allowed to differ.
>
> `task dr:apply-talos-configs` checks that every MAC in `terraform.tfvars` has
> a node in `talconfig.yaml`, not that the counts match. It matches by MAC and
> applies only to the VMs it finds, so the extra nodes are simply unused. What
> it refuses is a MAC with no config behind it — terraform would bring that VM
> up and nothing would ever configure it.
>
> To restore all three instead, add their MACs and IPs to `node_macs`/`node_ips`
> in `terraform.tfvars`. Nothing in `talconfig.yaml` needs touching either way.

### Option A — Terraform (automated, recommended)

> **First time on this machine:** Terraform needs a Proxmox API token.
> Proxmox → Datacenter → API Tokens → Add (user `root@pam`, token name `terraform`,
> privilege separation OFF — secret shown once). Then:
> ```bash
> cp talos/terraform/terraform.tfvars.example talos/terraform/terraform.tfvars
> # fill in proxmox_token_id and proxmox_token_secret
> ```
>
> **Storage layout on pve-2:** `local-zfs` for `disk_storage`, `media-isos`
> for `iso_storage` — the `local` storage there only has content=snippets,
> no iso support. Working DR config: `proxmox_nodes = ["pve-2", "pve-2", "pve-2"]`.

```bash
task dr:create-vms          # one VM per MAC in terraform.tfvars

# Wait ~60s for Talos maintenance mode, then:
# scans the subnet, identifies nodes by MAC, applies configs, waits for static IPs
task dr:apply-talos-configs
```

Nodes boot on DHCP in maintenance mode and reboot onto their static IPs from
`talconfig.yaml` once the config lands. Building the VMs by hand instead is
possible but pointless — match `terraform.tfvars` (cores, RAM, disk, MAC,
bridge, Talos ISO) and run the same second command.

---

## Phase 2 — Bootstrap Talos + Kubernetes

```bash
task bootstrap:talos        # etcd + kubeconfig
kubectl get nodes           # NotReady is normal — no CNI yet
```

The nodes install to disk and reboot before etcd will accept a bootstrap, so
the task retries for a couple of minutes. It skips re-applying configs when
`dr:apply-talos-configs` already placed them.

---

## Phase 3 — Bootstrap apps

```bash
# Installs Flux → Cilium → Longhorn → all cluster apps from Git (~5 min)
task bootstrap:apps

# Wait for Longhorn to be ready before restoring
kubectl get helmrelease longhorn -n longhorn-system -w
# Wait until READY = True, then Ctrl+C
```

---

## Phase 4 — Restore Longhorn volumes from S3

```bash
task longhorn:restore
```

**What it does (automatically):**
1. Patches BackupTarget → S3
2. Waits for BackupVolumes + Backup CRs to sync from Garage S3 (~60-90s)
3. Creates a restore Volume CRD for every PV in
   `kubernetes/apps/storage/restore-pvs/pvs.yaml` — currently 7: `jellyfin`,
   `jellyseerr`, `n8n`, `prowlarr`, `qbittorrent`, `radarr`, `sonarr`
4. Waits for replica initialization
5. Applies PV manifests with correct claimRefs
6. Fixes PVC field ownership (Flux SSA compatibility)
7. Creates `prometheus` + `alertmanager` PVCs fresh (observability is deliberately not backed up; `grafana`/`loki` PVCs are provisioned dynamically by their charts)
8. Force-reconciles all app HelmReleases
9. Waits for pods to settle, then clears HelmReleases left stalled by the
   volume-attach race (`flux reconcile --reset`)

**Expected duration:** ~10 min (only media/ARR config volumes download from S3; observability starts empty).

---

## Phase 5 — Verify

```bash
# All pods Running (see known exceptions below)
kubectl get pods -A | grep -v "Running\|Completed"

# All PVCs Bound
kubectl get pvc -A | grep -v "Bound\|NAME"

# Longhorn volumes healthy
kubectl get volumes.longhorn.io -n longhorn-system | grep restored

# HelmReleases OK
kubectl get helmreleases -A | grep -v "True\|READY"
```

**Expected in DR — not failures:**
- `jellyfin` and `jellyfin-public` → Pending: DR VMs have no iGPU, so nothing advertises `gpu.intel.com/i915`. Fix: patch both HelmReleases to drop the GPU resource request; they then transcode in software.
- Prometheus/Loki/Grafana/Netdata start with empty volumes — metrics/logs history is deliberately not backed up. Grafana dashboards come from git (sidecar provisioning).

---

## Phase 6 — Cleanup or failback

```bash
# Destroy DR VMs after test (or when ready to fail back to prod)
task dr:destroy-vms

# Restart the prod nodes — or `task dr:restore-prod`, which does this and
# clears the pods orphaned by the shutdown.
# Three nodes since 2026-09-04, one per host: VM 810 on pve-1, 811 on pve-2,
# 812 on pve-3. See talos/THREE-NODE.md.
```

---

## Known issues & fixes

15 problems hit during real DR runs, each already fixed in the repo:
**[docs/dr-known-issues.md](docs/dr-known-issues.md)**.

⚠️ Read it before "simplifying" anything in the restore path that looks
redundant — one row documents a cleanup that silently broke two prod apps
for two days.

---

## Backup schedule

The whole flow, and why it has the shape it has:
[docs/plan-nas-hot-r730-cold.md](docs/plan-nas-hot-r730-cold.md). Short
version, as of 2026-09-30:

| Source | Lands on the NAS, `backups/` | When (local) |
|---|---|---|
| Longhorn, 10 volumes | `longhorn/` via Garage on pve-3 | 02:50 |
| Garage metadata snapshots | `longhorn/meta-snapshots/` | every 6 h |
| pfSense config | `pfsense/config.xml.gz` | 03:00 |
| VPS services | `oracle-vps/` | 02:40 |

The NAS keeps the latest version only. **Until phase 7** of the plan the
R730xd is still the off-site path: pfSense and the VPS also send it a
dated copy, it reads `longhorn/` from the NAS over a read-only NFS mount, and
its nightly restic run pushes all of it to Oracle (append-only). After phase
7 the vault replaces the R730xd in that role.

Not backed up here, accepted as lost in DR: observability history, caches,
and the film library (tier 3). Photos and documents are not in the cluster:
they live on the NAS (Synology Photos, Synology Drive) and reach the vault and
Oracle from there.

```bash
# Last backup of each volume
kubectl -n longhorn-system get backupvolumes.longhorn.io | awk '{print $1, $6}'
```

## Longhorn backup store — total loss fallback

The store is Garage in CT 103 on pve-3 (`10.57.57.62:3900`, bucket
`longhorn`). Its **data** is on the NAS (`backups/longhorn/data`); its
**metadata** is on pve-3's local disk, with snapshots every 6 hours on the NAS
(`backups/longhorn/meta-snapshots/<timestamp>/db.lmdb`). The data directory
cannot be read without the metadata — that is why the snapshots exist.

| Lost | Recover from |
|---|---|
| pve-3 only | NAS: `data/` + newest meta snapshot |
| the NAS only | Longhorn replicas are intact; nothing to restore. Rebuild the NAS, let the next backup run |
| NAS and pve-3 | Oracle: restic path `/mnt/pve/nas-backups/longhorn` (after phase 7: the vault's snapshots first, then Oracle) |

**Rebuild Garage on the recovered tree:**

1. Provision a fresh CT 103 with `vps/playbooks/garage-setup.yml`, mounting the
   recovered `data/` as the data directory.
2. Stop Garage, copy the newest snapshot's `db.lmdb` to
   `meta/db.lmdb/data.mdb`, start it.
3. The node has a new ID: `garage layout assign` it with the same capacity,
   `garage layout apply`, then `garage bucket list` must show `longhorn`.
4. Repoint Longhorn if the address changed, then restore:

```bash
export SOPS_AGE_KEY_FILE=./age.key
sops set kubernetes/apps/storage/longhorn/app/minio-secret.sops.yaml \
  '["stringData"]["AWS_ENDPOINTS"]' '"http://<new-address>:3900"'
kubectl -n longhorn-system patch backuptargets.longhorn.io default --type=merge \
  -p "{\"spec\":{\"syncRequestedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}'
# expect: true, then:
task longhorn:restore
```

Reading the restic repository needs no host from this site: on the VPS, as a
sudoer, with the repo password from the password manager — see
[proxmox/pve-2/README.md](proxmox/pve-2/README.md#pve-2--oracle-restic).

Drilled: a restore from the new store into a scratch volume, 2026-09-30
(Prowlarr, config and SQLite database intact). **Not yet drilled:** rebuilding
Garage from a metadata snapshot. Do it once before trusting steps 2-3; the
vault's first month is the natural moment.
