# Disaster Recovery Runbook

Restore the full K8s cluster from Longhorn S3 backups onto fresh Talos nodes.  
**Tested end-to-end: 2026-06-06. Total time: ~35 min.**

**You need:** `age.key`, `talos/talsecret.sops.yaml` (or a full re-bootstrap), access to Proxmox.

---

## Phase 1 — Provision DR nodes

### Option A — Terraform (automated, recommended)

```bash
cd /srv/kubernetes/infrastructure

# Creates 3 VMs on Proxmox px-0 (500 GB disk, prod MACs → static IPs via talconfig)
task dr:create-vms

# Wait ~60s for Talos maintenance mode, then:
# Scans subnet, identifies nodes by MAC, applies static-IP configs, waits for .80/.82/.84
task dr:apply-talos-configs
```

### Option B — Manual (no Terraform)

Create 3 VMs on Proxmox manually with these settings:

| Setting | Value |
|---|---|
| OS | Talos v1.13.3 ISO (`factory.talos.dev/image/8d37fcc.../v1.13.3/metal-amd64.iso`) |
| CPU | 4 vCPU, type: host |
| RAM | 8 GB |
| Disk | 500 GB (scsi, local-data) |
| Network | vmbr0 |
| MAC addresses | `bc:24:11:a7:ba:13` / `bc:24:11:a5:4b:9e` / `bc:24:11:0e:cd:ab` |

Then apply configs (same as Option A — the task scans the subnet):
```bash
task dr:apply-talos-configs
```

**After either option:** nodes reboot with static IPs `10.57.57.80 / .82 / .84` (from talconfig, `dhcp: false`).

---

## Phase 2 — Bootstrap Talos + Kubernetes

```bash
cd /srv/kubernetes/infrastructure

# Bootstrap etcd (run until it succeeds — takes a few seconds)
until talhelper gencommand bootstrap | bash; do sleep 10; done

# Get kubeconfig
until talhelper gencommand kubeconfig --extra-flags="$(pwd) --force" | bash; do sleep 10; done

# Verify (NotReady is normal — CNI not yet installed)
kubectl get nodes
```

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
3. Creates restore Volume CRDs for: `jellyfin`, `jellyseerr`, `prowlarr`, `qbittorrent`, `radarr`, `sonarr`
4. Waits for replica initialization
5. Applies PV manifests with correct claimRefs
6. Fixes PVC field ownership (Flux SSA compatibility)
7. Creates `prometheus` + `alertmanager` PVCs fresh (observability is deliberately not backed up; `grafana`/`loki` PVCs are provisioned dynamically by their charts)
8. Force-reconciles all app HelmReleases

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
- `jellyfin` → Pending: DR VMs have no Intel GPU (`gpu.intel.com/i915`). Jellyfin runs but hardware transcoding unavailable. Fix: patch Jellyfin HelmRelease to remove the GPU resource request.
- Prometheus/Loki/Grafana/Netdata start with empty volumes — metrics/logs history is deliberately not backed up. Grafana dashboards come from git (sidecar provisioning).

---

## Phase 6 — Cleanup or failback

```bash
# Destroy DR VMs after test (or when ready to fail back to prod)
task dr:destroy-vms

# Restart prod nodes via Proxmox UI:
# VM 800 → kubernetes-controlplane-1 (px-0)
# VM 801 → kubernetes-controlplane-2 (px-1)
# VM 104 → kubernetes-controlplane-3 (px-2)
```

---

## Known issues & fixes (already in repo)

| Symptom | Root cause | Fix applied |
|---|---|---|
| DR nodes get `.206/.207/.208` in maintenance mode | Talos always uses DHCP before config is applied | `dr:apply-talos-configs` scans subnet by MAC → applies config → nodes reboot with static IPs |
| Longhorn disks not created on fresh DR nodes | `createDefaultDiskLabeledNodes: true` requires a node label that DR nodes don't have | Set to `false` in HelmRelease — disks created on all nodes automatically |
| `restore-volume` prints "no backup URL" and skips | Longhorn 1.12.0 removed `lastBackupURL` | Fixed: use `lastBackupName` → lookup `Backup.status.url` |
| First volumes skip with "no backup URL" on fresh restore | `BackupVolume` objects sync fast but individual `Backup` CR objects take ~30s longer | Added wait step in `wait-for-backup-volumes` that confirms Backup CRs have URLs before proceeding |
| Grafana/Loki PVCs stay Pending after rebind | After PVC delete, PV goes to `Released` but keeps old `claimRef` → Kubernetes refuses to rebind | `create-statefulset-pvcs` now clears the stale `claimRef` before recreating the PVC |
| `task bootstrap:talos` fails if configs already applied | Task tries to apply configs with `--insecure` but nodes already have TLS | Run bootstrap steps manually (skip `gencommand apply --insecure`) |

---

## Backup schedule

- **Daily at 02:00** — Longhorn RecurringJob (group `media`) backs up opted-in volumes to Garage S3 on Oracle VPS (via Tailscale)
- **Retention:** 3 backups per volume
- **Volumes backed up:** `jellyfin`, `jellyseerr`, `prowlarr`, `qbittorrent`, `radarr`, `sonarr` — opted in via PVC label `recurring-job-group.longhorn.io/media: enabled`
- **Deliberately NOT backed up:** observability (prometheus/loki/grafana/alertmanager/netdata), all `*-cache` volumes — regenerable, history accepted as lost in DR
- **Off-site:** the NAS pulls the whole Garage bucket + VPS dumps nightly at 03:30 → `/volume1/Server/oracle-vps-backups/` (see `vps/roles/vps_backup/README.md`)

```bash
# Check last backup time for each volume
kubectl get backupvolumes.longhorn.io -n longhorn-system | awk '{print $1, $6}'
```
