# Disaster Recovery Runbook

Restore the full K8s cluster from Longhorn S3 backups onto fresh Talos nodes.  
**Tested end-to-end: 2026-06-06. Total time: ~35 min.**

**You need:** `age.key`, `talos/talsecret.sops.yaml` (or a full re-bootstrap), access to Proxmox.

---

## Phase 1 — Provision DR nodes

### Option A — Terraform (automated, recommended)

> **First time on this machine:** Terraform needs a Proxmox API token.
> Proxmox → Datacenter → API Tokens → Add (user `root@pam`, token name `terraform`,
> privilege separation OFF — secret shown once). Then:
> ```bash
> cp talos/terraform/terraform.tfvars.example talos/terraform/terraform.tfvars
> # fill in proxmox_token_id and proxmox_token_secret
> ```
>
> **Storage layout on this cluster** (discovered DR 2026-06-04): `cluster-storage`
> exists only on px-0; `local-data` exists on all nodes but is node-local — an ISO
> downloaded on one node can't be used by VMs on another. Working DR config:
> `proxmox_nodes = ["px-0", "px-0", "px-0"]`, `disk_storage = "local-data"`.

```bash
cd /srv/kubernetes/infrastructure

# Creates 3 VMs on Proxmox px-0 (500 GB disk, prod MACs → static IPs via talconfig)
# (runs terraform apply interactively — for non-interactive use:
#  cd talos/terraform && terraform init && terraform apply -auto-approve)
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
# VM 800 → kubernetes-controlplane-1 (pve / R730xd)
# VM 802 → kubernetes-controlplane-2 (px-0 / Beelink)
# VM 804 → kubernetes-controlplane-3 (px-0 / Beelink)
# (px-1/px-2 OptiPlexes are retired - controlplane-2/3 live on px-0 now, not there)
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

Full nightly schedule, what's included/excluded: VPS-side —
**[vps/roles/vps_backup/README.md](vps/roles/vps_backup/README.md)**; R730xd-side —
**[proxmox/r730xd/README.md](proxmox/r730xd/README.md)**.
Short version: Longhorn backs up the media/ARR config volumes nightly to a
self-hosted Garage instance on the R730xd (`10.57.57.61:3900`, bucket
`longhorn`) — not the VPS anymore. From there, R730xd relays a curated copy
weekly to Synology (cold storage), and Synology relays that same copy
onward to the Oracle VPS via Hyper Backup — the full mesh is documented in
[proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs).
Observability history and caches are deliberately not backed up (accepted as
lost in DR).

```bash
# Check last backup time for each volume
kubectl get backupvolumes.longhorn.io -n longhorn-system | awk '{print $1, $6}'
```

### Immich Postgres backup

Immich's Postgres (albums, face tags, favorites, sharing links — the
metadata, not the photo files themselves) has **two independent backup
paths**, deliberately not just one:

1. **Longhorn → Garage S3**, same mechanism as Jellyfin/Sonarr/Radarr/
   Prowlarr — `immich-postgres`'s PVC carries the `media` recurring-job-group
   label, so it's included automatically in `task longhorn:restore` on a
   full cluster rebuild (see `.taskfiles/longhorn/Taskfile.yaml`).
2. **Nightly `pg_dump`** via a k8s CronJob (`immich-postgres-backup`, 03:30,
   after the other 02:xx-03:xx jobs), landing gzipped on
   `/media/backups/immich-postgres/` on the R730xd, 30-day retention — an
   independent, storage-format-agnostic path that survives even if Longhorn/
   Garage itself has a bad day. See
   [docs/immich-post-restore.md](docs/immich-post-restore.md) for the manual
   restore procedure and the one-time VectorChord extension setup a fresh
   Postgres needs.

**What neither path covers**: the actual photo/video files, which live on
`/media/photos` — not a Longhorn volume at all, just an NFS mount from the
R730xd's SAS pool. Those are protected by RAIDZ2 (survives 1-2 disk
failures), a weekly versioned copy pushed to Synology, and (as of
2026-07-23) Synology's own Hyper Backup relay onward to the Oracle VPS — see
[proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs) for the
full chain. Both offsite legs (R730xd→Synology, Synology→Oracle) are built
and running; the R730xd→Synology→Oracle chain still hasn't been drilled as
a full restore end-to-end (see "R730xd / Garage total loss fallback" below).

## R730xd / Garage total loss fallback

Longhorn's primary backup target lives on the same physical host as
`kubernetes-controlplane-1` (the R730xd, Garage LXC 103). If R730xd is lost
entirely, `task longhorn:restore` has nothing to read from until a Garage
instance is rebuilt from one of the downstream copies. In order of
preference:

**1. Synology's copy** (fastest, most complete, no decryption needed):

```bash
# Wake Synology if asleep (it's only awake Sun 02:50-03:40 otherwise):
wakeonlan 90:09:d0:50:08:4b
# wait ~1-2 min, then confirm it's up:
ping 10.57.57.201

# The data:
ssh admin@10.57.57.201 "ls /volume1/NetBackup/longhorn-garage/"
# Pick the latest dated folder, e.g. 2026-07-23 — copy data/ and meta/ from
# it to wherever the new Garage instance (step 3 below) will read from:
scp -r admin@10.57.57.201:/volume1/NetBackup/longhorn-garage/<latest-date>/ \
  /tmp/garage-recovered/
```

**2. Oracle's copy, if Synology is ALSO gone** — this is NOT a plain file
mirror. It went there via DSM Hyper Backup (see
[proxmox/r730xd/README.md](proxmox/r730xd/README.md#synology--oracle-cloud-done-2026-07-23)),
which stores backups in its own versioned/chunked vault format on the VPS's
`/backup/synology` rsync destination — you cannot just `rsync` the files
back out. **You need a working DSM instance** (a spare physical Synology, or
a temporary [Virtual DSM](https://www.synology.com/en-global/dsm/virtual_dsm)
VM) to run Hyper Backup's own restore wizard:

```
1. On any DSM instance: Hyper Backup → "Restore" → data source type "Rsync"
   → same connection details as the original task (see
   proxmox/r730xd/README.md for server/port/module/credentials — the
   password is vault_rsyncd_password, same VPS, same synology_backup module).
2. Pick the longhorn-garage folder from within the restored NetBackup tree,
   restore it to a local path.
3. Proceed with step 3 below using that restored data.
```

If this DSM-dependency turns out to be too fragile as a real fallback,
revisit — a plain rsync/restic based offsite leg (no proprietary restore
tool needed) may be worth adding specifically for Garage's data, even
though the DSM-based leg is fine for everything else.

**3. Stand up a fresh Garage instance** anywhere reachable from the cluster
(a new LXC on `px-0`, or temporarily the VPS itself) with the recovered
`data`/`meta` directories bind-mounted in — reusing `vps/roles/garage_setup`
(`garage_require_tailscale`/`garage_webui_enabled` set per the new host,
same as `vps/playbooks/garage-setup-r730xd.yml`).

**4. Repoint Longhorn at it:**

```bash
export SOPS_AGE_KEY_FILE=./age.key
sops -d -i kubernetes/apps/storage/longhorn/app/minio-secret.sops.yaml
# edit AWS_ENDPOINTS to the new instance's address:port
sops -e -i kubernetes/apps/storage/longhorn/app/minio-secret.sops.yaml
kubectl -n longhorn-system patch backuptargets.longhorn.io default --type=merge \
  -p "{\"spec\":{\"syncRequestedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}'
# expect: true, then:
task longhorn:restore
```

This procedure hasn't been drilled end-to-end yet — treat it as a documented
starting point, not a tested runbook, until it's actually rehearsed once.
Path 1 (Synology reachable) is the realistic common case; path 2 (both
R730xd and Synology gone) is the untested, DSM-dependent edge case.
