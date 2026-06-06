# Disaster Recovery Runbook

Full cluster restore from S3 backups onto fresh Talos VMs. Tested 2026-06-06.

**Prerequisites:** `age.key`, `talos/.vault_pass`, `.sops.yaml` all present on the infra server.  
**Time:** ~30-40 min total.

---

## Phase 1 — Provision DR cluster

```bash
cd /srv/kubernetes/infrastructure

# 1. Create 3 Talos VMs on Proxmox (500 GB disk, prod MACs → same IPs via talconfig static)
task dr:create-vms

# 2. Wait ~60s, then apply Talos configs (scans subnet, matches MACs, applies static IPs)
task dr:apply-talos-configs
# → nodes reboot to 10.57.57.80 / .82 / .84

# 3. Bootstrap etcd + get kubeconfig
cd talos
until talhelper gencommand bootstrap | bash; do sleep 10; done
until talhelper gencommand kubeconfig --extra-flags="/srv/kubernetes/infrastructure --force" | bash; do sleep 10; done
cd ..

# 4. Verify cluster (NotReady is normal — CNI not installed yet)
kubectl get nodes
```

---

## Phase 2 — Bootstrap apps

```bash
# Installs Flux, Cilium, Longhorn + all cluster apps from Git
task bootstrap:apps

# Wait for Longhorn HelmRelease to be Ready (~3-5 min)
kubectl get helmrelease longhorn -n longhorn-system -w
# When READY=True, proceed
```

---

## Phase 3 — Restore Longhorn volumes from S3

```bash
# Full restore pipeline (BackupTarget → BackupVolumes → restore volumes →
# PVs → PVC ownership → statefulset PVCs → app reconcile)
task longhorn:restore
```

**What this does:**
1. Patches BackupTarget with S3 credentials
2. Waits for BackupVolumes + Backup CRs to sync from S3 (~60-90s)
3. Creates restore Volume CRDs for: jellyfin, jellyseerr, prowlarr, qbittorrent, radarr, sonarr, loki, prometheus, grafana
4. Waits for replica initialization
5. Applies PV manifests with correct claimRefs
6. Fixes PVC field ownership (prevents Flux SSA conflicts)
7. Rebinds grafana + loki PVCs to restored PVs (clears stale Released PV claimRef)
8. Creates alertmanager PVC (fresh, no backup)
9. Force-reconciles all app HelmReleases

---

## Phase 4 — Verify

```bash
# All pods Running (except jellyfin which needs Intel GPU — not in DR VMs)
kubectl get pods -A | grep -v Running | grep -v Completed

# All PVCs Bound
kubectl get pvc -A | grep -v Bound | grep -v NAME

# Longhorn volumes healthy
kubectl get volumes.longhorn.io -n longhorn-system | grep restored

# HelmReleases OK
kubectl get helmreleases -A | grep -v True | grep -v READY
```

Expected in DR (not failures):
- `jellyfin` Pending → no `gpu.intel.com/i915` in DR VMs (hardware transcoding not available)

---

## Phase 5 — Cleanup / Failback

```bash
# Destroy DR VMs (after prod is confirmed dead or you're done testing)
task dr:destroy-vms

# Restart prod VMs via Proxmox UI or API:
# VM 800 (px-0 / kubernetes-controlplane-1)
# VM 801 (px-1 / kubernetes-controlplane-2)  
# VM 104 (px-2 / kubernetes-controlplane-3)
```

---

## Known issues & fixes applied

| Issue | Fix |
|---|---|
| DR nodes get random DHCP IPs in maintenance mode | `dr:apply-talos-configs` scans whole subnet by MAC — static IPs set in talconfig kick in after reboot |
| Longhorn disks not created on fresh nodes | `createDefaultDiskLabeledNodes: false` in HelmRelease (no label needed) |
| `restore-volume` fails with "no backup URL" | Fixed: uses `lastBackupName` → `Backup.status.url` (Longhorn 1.12.0 removed `lastBackupURL`) |
| First volumes skip with "no backup URL" on fresh restore | Fixed: `wait-for-backup-volumes` now waits for Backup CRs to populate URLs before proceeding |
| Grafana/Loki PVCs stay Pending after rebind | Fixed: `create-statefulset-pvcs` clears stale `claimRef` on Released PVs before recreating PVC |
| `task bootstrap:talos` fails if configs already applied | Run the bootstrap commands manually (skip `gencommand apply --insecure`) |

---

## S3 backup schedule

Backups run daily at 02:00 via Longhorn RecurringJob → Garage S3 (via Tailscale).  
Retention: 7 snapshots per volume.

Key volumes backed up:
- `jellyfin`, `jellyseerr`, `prowlarr`, `qbittorrent`, `radarr`, `sonarr` (media stack)
- `grafana`, `loki`, `prometheus` (observability)
