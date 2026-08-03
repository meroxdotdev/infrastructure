# Disaster Recovery Runbook

Restore the full K8s cluster from Longhorn S3 backups onto fresh Talos nodes.  
**Tested end-to-end: 2026-06-06 (px-0) and 2026-08-03 (pve/R730xd, prod VMs
stopped-not-deleted throughout, restarted clean afterward). Total time: ~45 min
including troubleshooting; a clean run with today's fixes applied should be
back to ~35 min.**

**You need:** `age.key`, `talos/talsecret.sops.yaml` (or a full re-bootstrap), access to Proxmox.

**In a hurry?** [`docs/dr-quickstart.md`](docs/dr-quickstart.md) is the same
procedure with no explanations — commands only.

## Which host to target

| Target | Tests | Trade-off |
|---|---|---|
| **px-0** | Real host-failure DR (prod lives on R730xd) | Only ~50GB RAM free — 8GB/node (default) is NOT enough to schedule the full stack; use `vm_memory_mb = 16384` minimum, and even then it's below prod's 48GB/node |
| **pve (R730xd)** | Restore procedure only, not host failure (same physical box) | 238GB+ RAM free once prod VMs are stopped — can match prod exactly (`vm_memory_mb = 49152`), so nothing gets stuck on scheduling |

Both are valid DR drills for different purposes — px-0 for "the R730xd died,
can we recover," pve for "did we break the restore procedure with recent
changes" (faster, no resource-sizing surprises).

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
3. Creates restore Volume CRDs for: `jellyfin`, `prowlarr`, `radarr`, `sonarr`, `immich-postgres`, `n8n`
   (`jellyseerr`/`qbittorrent` dropped from backup 2026-07-21 — start empty, dynamically provisioned)
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
- `jellyfin` → Pending: DR VMs have no Nvidia GPU (`nvidia.com/gpu`). Jellyfin runs but hardware transcoding unavailable. Fix: patch Jellyfin HelmRelease to remove the GPU resource request and `runtimeClassName: nvidia`.
- Prometheus/Loki/Grafana/Netdata start with empty volumes — metrics/logs history is deliberately not backed up. Grafana dashboards come from git (sidecar provisioning).

---

## Phase 6 — Cleanup or failback

```bash
# Destroy DR VMs after test (or when ready to fail back to prod)
task dr:destroy-vms

# Restart prod nodes via Proxmox UI:
# VM 800 → kubernetes-controlplane-1 (pve / R730xd)
# VM 802 → kubernetes-controlplane-2 (pve / R730xd)
# VM 804 → kubernetes-controlplane-3 (pve / R730xd)
# (verified live 2026-08-02: all 3 control-plane VMs run on R730xd, not
# split across px-0/Beelink as previously documented here. px-0 now hosts
# datacenter-manager (100), winserver (102, stopped), ollama (105) instead.
# px-1/px-2 OptiPlexes remain retired.)
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
| `bootstrap:apps` fails: prometheus-operator CRD "cannot be imported into the current release" | `apply_crds()` raw-applies these CRDs (Cilium's ServiceMonitor needs them before its HelmRelease runs) with field-manager `kubectl`; the `prometheus-operator-crds` chart installs the *same* CRDs later in the same sync and refuses to adopt them | `apply_crds()` now pre-applies them with `--field-manager=helm --force-conflicts` and the chart's adoption labels already set, so the later `helm install` sees them as already its own |
| `bootstrap:apps` fails: `no matches for kind "ServiceMonitor"` | Removing the raw prometheus CRD pre-apply entirely (the "obvious" fix for the row above) breaks Cilium, which needs the CRD to exist *before* its own HelmRelease | Don't remove the pre-apply — fix its field-manager/labels instead (see row above) |
| `immich-postgres`/`n8n` restore silently aborts mid-script | Their Longhorn `BackupVolume` is named `pvc-<uuid>-<hash>` (dynamically-provisioned PVC), not `{app}-restored-<hash>` like the ARR apps — the prefix `grep` finds nothing, and under this script's `set -e` an unmatched `grep` (exit 1) kills the whole restore right there, silently, with no error message | `restore-volume` now falls back to matching by `KubernetesStatus.pvcName` in the BackupVolume's labels when the prefix match fails (pass `PVC_NAME` var) |
| `immich-postgres`/`n8n` PVC binds to a fresh **empty** volume instead of the restored one | `bootstrap:apps` (Phase 3) already reconciled every Kustomization, including these two, before `longhorn:restore` (Phase 4) runs — their PVCs (plain, dynamically-provisioned, unlike the ARR apps' static claimRef'd PVs) get created and dynamic-provisioned immediately, "winning" the race against the restore | New `unbind-premature-dynamic-pvcs` task (runs before `apply-pvs`) deletes the pod+PVC if bound to a non-`*-restored-pv` volume, so `reconcile-apps` recreates it correctly bound afterward |
| `jellyseerr`/`qbittorrent`/`prometheus` PVCs stuck `FailedAttachVolume: not found` | `pvs.yaml` still declared static PVs for these three pointing at Longhorn volumes that no longer exist (jellyseerr/qbittorrent dropped from backup 2026-07-21; prometheus was never backed up) — `apply-pvs` recreates the dead PV every run, and it wins the PVC bind race before the dynamic provisioner can | Removed all three dead PV blocks from `pvs.yaml` — those three now get fresh dynamic volumes like the rest of observability |
| `terraform apply` fails: `storage 'local-data' does not support vm images` | px-0's `local-data` storage had its content-type changed (sometime after the 2026-06 tests) to `iso,import,vztmpl,snippets` — no longer `images` | Use `cluster-storage` for `disk_storage` on px-0 (still `local-data` for `iso_storage`) — already fixed in `terraform.tfvars.example` |
| DR node never gets its static IP, `dr:apply-talos-configs` reports `UNKNOWN` MAC | `terraform.tfvars.example`'s `node_macs` had a stale MAC for controlplane-3 that no longer matches the real prod VM's NIC (`talconfig.yaml` is the source of truth, always re-verify against it) | Fixed in `terraform.tfvars.example`; if this happens again, `qm set <vmid> -net0 virtio=<correct-mac>,bridge=vmbr0` + reboot the VM |
| `bootstrap:apps`/`longhorn:restore` fail with `task: Unsupported bash version` or `Missing required deps` | macOS ships bash 3.2 (Taskfile needs 4+); `helmfile`/`kustomize` aren't installed by default outside the `mise` toolchain | `brew install bash helmfile kustomize` once per machine, run with `/opt/homebrew/bin` ahead of `/usr/bin` on `PATH` |

---

## Backup schedule

Full nightly schedule, what's included/excluded: VPS-side —
**[vps/roles/vps_backup/README.md](vps/roles/vps_backup/README.md)**; R730xd-side —
**[proxmox/r730xd/README.md](proxmox/r730xd/README.md)**.
Short version: Longhorn backs up the media/ARR config volumes nightly to a
self-hosted Garage instance on the R730xd (`10.57.57.61:3900`, bucket
`longhorn`) — not the VPS anymore. From there, R730xd relays a curated copy
weekly to Synology (cold storage) *and* nightly, directly, via restic to
the Oracle VPS (open format, no DSM dependency — replaced a Synology→Oracle
Hyper Backup relay retired 2026-07-26 once this leg covered the same
ground and was proven with a real restore drill). The full mesh is
documented in [proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs).
Observability history and caches are deliberately not backed up (accepted as
lost in DR).

**Alerting**: the VPS-side backup scripts and the Immich pg_dump CronJob all
ping healthchecks.io on success/failure (same account as the cluster's
Watchdog heartbeat) — see
[vps/roles/vps_backup/README.md](vps/roles/vps_backup/README.md#alerting-healthchecksio).

**Restore drill**: a monthly cron actually restores the latest Authentik/
Joplin dumps into throwaway containers to prove they're valid, not just
present — see
[vps/roles/vps_backup/README.md](vps/roles/vps_backup/README.md#restore-drill-monthly).

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
failures), a weekly versioned copy pushed to Synology, and a nightly
restic push direct to Oracle (see
[proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs) for the
full chain) — the restic leg has been drilled end-to-end (monthly
`restic-restore-drill.sh`, first run 2026-07-26: restored content verified
byte-for-byte against the live source).

## R730xd / Garage total loss fallback

Longhorn's primary backup target lives on the same physical host as
`kubernetes-controlplane-1` (the R730xd, Garage LXC 103) — R730xd being both
a live cluster node and the backup hub is a real, accepted blast-radius
tradeoff (see [proxmox/r730xd/README.md](proxmox/r730xd/README.md), end of
"Synology → Oracle Cloud"). Two independent mitigations exist: daily ZFS
snapshots on `media/backups` (protects against corruption/deletion
*propagating outward*, not R730xd loss itself) and the downstream copies
below (protect against R730xd loss). If R730xd is lost entirely,
`task longhorn:restore` has nothing to read from until a Garage instance is
rebuilt from one of the downstream copies. In order of preference:

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

**2. Oracle's restic copy, if Synology is ALSO gone** — as of 2026-07-26
this no longer needs DSM at all. The old path (Synology → Oracle via Hyper
Backup, proprietary chunked vault format, needed a working DSM/Virtual DSM
instance just to restore) was retired once R730xd's own restic-push-oracle.sh
leg was extended to cover `longhorn-garage/` directly:

```bash
export RESTIC_REPOSITORY="sftp:restic-backup@100.72.22.38:/data"
export RESTIC_PASSWORD_FILE=/path/to/saved/password   # see proxmox/r730xd/README.md
restic restore latest --include /media/backups/longhorn-garage --target /tmp/garage-recovered
# data/ and meta/ land under /tmp/garage-recovered/media/backups/longhorn-garage/
```

Just the `restic` binary (any OS) and the repo password — no DSM, no
Virtual DSM VM, no restore wizard. Proceed with step 3 below using that
recovered data.

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
