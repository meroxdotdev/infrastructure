# Disaster Recovery Runbook

Restore the full K8s cluster from Longhorn S3 backups onto fresh Talos nodes.

- **You need:** `age.key`, `talos/talsecret.sops.yaml` (or a full
  re-bootstrap), access to Proxmox.
- **In a hurry:** [`docs/dr-quickstart.md`](docs/dr-quickstart.md) — same
  procedure, commands only.
- **Rebuilding a host instead of the cluster:**
  [pve](proxmox/r730xd/REINSTALL.md) · [px-0](proxmox/px-0/REINSTALL.md) ·
  [pfSense](pfsense/REINSTALL.md)

**Tested end-to-end:** 2026-06-06 (px-0), 2026-08-03 (pve/R730xd — prod VMs
stopped, not deleted, restarted clean afterward). ~45 min with
troubleshooting; ~35 min clean.

## Which host to target

| Target | Tests | Trade-off |
|---|---|---|
| **px-0** | Real host-failure DR (prod lives on R730xd) | Only ~50GB RAM free — 8GB/node (default) is NOT enough to schedule the full stack; use `vm_memory_mb = 16384` minimum, and even then it's below prod's 48GB/node |
| **pve (R730xd)** | Restore procedure only, not host failure (same physical box) | 238GB+ RAM free once prod VMs are stopped — can match prod exactly (`vm_memory_mb = 49152`), so nothing gets stuck on scheduling |

Both are valid drills, for different questions:

- **px-0** — "the R730xd died, can we recover?"
- **pve** — "did recent changes break the restore procedure?" Faster, no
  resource-sizing surprises.

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
| `prometheus` PVC stuck `FailedAttachVolume: not found` on a **fresh DR restore** | `pvs.yaml` declared a static PV pointing at a Longhorn volume that was never backed up, so it doesn't exist on a from-scratch cluster — `apply-pvs` recreates the dead PV every run, winning the PVC bind race before the dynamic provisioner can | Removed the dead PV block from `pvs.yaml` — prometheus gets a fresh dynamic volume like the rest of observability |
| ⚠️ `jellyseerr`/`qbittorrent` static PVs looked dead by the same logic, but weren't — **do not remove them again** | 2026-08-03's first pass at the row above also dropped `jellyseerr-restored-pv`/`qbittorrent-restored-pv` from `pvs.yaml`, reasoning they were "dropped from backup 2026-07-21, no longer exist" — true for a fresh DR cluster (never backed up = genuinely absent there), false for **prod** (`pve`/R730xd), where those exact Longhorn volumes are the live, real, un-backed-up app data and still existed with real content. Removing them from git deleted the PVs off prod too (same manifest, same `longhorn` Kustomization, no DR/prod distinction) — `kubernetes.io/pv-protection` blocked full deletion since the PVCs were still bound, so both PVs sat `Terminating` for 2 days, silently breaking both apps, until caught 2026-08-05 | Re-added both PV blocks (`9af0230`) — same `volumeHandle`, so they rebind to the existing Longhorn volume instead of provisioning empty. **If jellyseerr/qbittorrent are still excluded from the nightly `media` backup group, this recovered data has no ongoing backup protection** — confirm that's intentional, or re-add the `recurring-job-group.longhorn.io/media` label |
| `terraform apply` fails: `storage 'local-data' does not support vm images` | px-0's `local-data` storage had its content-type changed (sometime after the 2026-06 tests) to `iso,import,vztmpl,snippets` — no longer `images` | Use `cluster-storage` for `disk_storage` on px-0 (still `local-data` for `iso_storage`) — already fixed in `terraform.tfvars.example` |
| DR node never gets its static IP, `dr:apply-talos-configs` reports `UNKNOWN` MAC | `terraform.tfvars.example`'s `node_macs` had a stale MAC for controlplane-3 that no longer matches the real prod VM's NIC (`talconfig.yaml` is the source of truth, always re-verify against it) | Fixed in `terraform.tfvars.example`; if this happens again, `qm set <vmid> -net0 virtio=<correct-mac>,bridge=vmbr0` + reboot the VM |
| `bootstrap:apps`/`longhorn:restore` fail with `task: Unsupported bash version` or `Missing required deps` | macOS ships bash 3.2 (Taskfile needs 4+); `helmfile`/`kustomize` aren't installed by default outside the `mise` toolchain | `brew install bash helmfile kustomize` once per machine, run with `/opt/homebrew/bin` ahead of `/usr/bin` on `PATH` |

---

## Backup schedule

Canonical schedules: [VPS side](vps/roles/vps_backup/README.md) ·
[R730xd side](proxmox/r730xd/README.md#downstream-legs).

Short version:

1. Longhorn → Garage on the R730xd (`10.57.57.61:3900`, bucket `longhorn`),
   nightly. Media/ARR config volumes. Not the VPS anymore.
2. R730xd → Synology, weekly, curated copy, cold storage.
3. R730xd → Oracle, nightly, restic over SFTP. Open format, no DSM
   dependency — replaced the Synology→Oracle Hyper Backup relay (retired
   2026-07-26) once proven with a real restore drill.

Not backed up, accepted as lost in DR: observability history and caches.

- **Alerting** — VPS backup scripts and the Immich pg_dump CronJob ping
  healthchecks.io on success/failure, same account as the cluster Watchdog.
  [Detail](vps/roles/vps_backup/README.md#alerting-healthchecksio)
- **Restore drill** — monthly cron restores the latest Authentik/Joplin
  dumps into throwaway containers, proving they're valid and not merely
  present. [Detail](vps/roles/vps_backup/README.md#restore-drill-monthly)

```bash
# Check last backup time for each volume
kubectl get backupvolumes.longhorn.io -n longhorn-system | awk '{print $1, $6}'
```

### Immich Postgres backup

Postgres holds albums, face tags, favorites and sharing links — the
metadata, not the files. **Two independent paths, deliberately:**

1. **Longhorn → Garage S3** — same mechanism as the ARR apps. The
   `immich-postgres` PVC carries the `media` recurring-job-group label, so
   `task longhorn:restore` picks it up automatically.
2. **Nightly `pg_dump`** — CronJob `immich-postgres-backup`, 03:02, gzipped
   to `/media/backups/immich-postgres/`, 30-day retention. Storage-format
   agnostic, survives Longhorn/Garage having a bad day. Restore procedure +
   the one-time VectorChord setup a fresh Postgres needs:
   [docs/immich-post-restore.md](docs/immich-post-restore.md).

**Photo/video files** moved off the SAS pool 2026-08-06 → now
`immich-library-ssd` / `immich-external-library-ssd`, Longhorn PVCs on
rpool (SSD). Same `media` label, so Longhorn → Garage is their primary
protection too.

⚠️ `/media/photos` is a **stale leftover**, not live Immich data. The
export still exists (Filebrowser reads it; briefly removed 2026-08-06,
which broke Filebrowser, re-added 2026-08-07), and the weekly Synology and
nightly restic legs still copy it. Fine as a second safety net — do not
treat it as current.

## R730xd / Garage total loss fallback

Longhorn's backup target (Garage LXC 103) sits on the same physical host as
`kubernetes-controlplane-1`. R730xd being both a live cluster node and the
backup hub is an accepted blast-radius tradeoff.

Mitigations:

- **ZFS snapshots** on `media/backups`, daily — cover corruption and
  deletion propagating outward, *not* R730xd loss.
- **Downstream copies** below — cover R730xd loss.

If R730xd is gone, `task longhorn:restore` has nothing to read until a
Garage instance is rebuilt from one of those copies. In order of
preference:

**1. Synology's copy** (fastest, most complete, no decryption needed):

```bash
# Wake Synology if asleep (it sleeps outside a short weekly window - wake
# schedule and WoL MAC are in /root/PRIVATE-NOTES.md on pve, deliberately
# not in this public repo):
wakeonlan <MAC-from-private-notes>
# wait ~1-2 min, then confirm it's up:
ping 10.57.57.201

# The data:
ssh admin@10.57.57.201 "ls /volume1/NetBackup/longhorn-garage/"
# Pick the latest dated folder, e.g. 2026-07-23 — copy data/ and meta/ from
# it to wherever the new Garage instance (step 3 below) will read from:
scp -r admin@10.57.57.201:/volume1/NetBackup/longhorn-garage/<latest-date>/ \
  /tmp/garage-recovered/
```

**2. Oracle's restic copy, if Synology is ALSO gone.** Needs only the
`restic` binary (any OS) and the repo password — no DSM, no Virtual DSM, no
restore wizard. The old Hyper Backup path (proprietary chunked vault,
required a working DSM to read) was retired 2026-07-26.

```bash
# On pve, "oracle-vps-restic" is an ~/.ssh/config alias — off-host, use the
# real target + key, both recoverable from /root once you can read the repo.
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
export RESTIC_PASSWORD_FILE=/path/to/saved/password   # password manager, "restic bak password"
restic restore latest --include /media/backups/longhorn-garage --target /tmp/garage-recovered
# data/ and meta/ land under /tmp/garage-recovered/media/backups/longhorn-garage/
```

**3. Stand up a fresh Garage instance** anywhere the cluster can reach — a
new LXC on `px-0`, or the VPS temporarily — with the recovered
`data`/`meta` bind-mounted in. Reuse `vps/roles/garage_setup`, setting
`garage_require_tailscale` / `garage_webui_enabled` per host, same as
`vps/playbooks/garage-setup-r730xd.yml`.

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

⚠️ **Not drilled end-to-end.** Treat this section as a documented starting
point, not a tested runbook, until it's rehearsed once. Path 1 (Synology
reachable) is the realistic case; path 2 (R730xd *and* Synology gone) is
the untested edge case.
