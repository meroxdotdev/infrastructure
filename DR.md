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

> **Prerequisite as of the 2026-08-17 single-node downsize:** production now
> runs 1 control-plane node, but DR always provisions 3 (deliberately — it
> exercises recovery independent of prod's current node count).
> `talos/talconfig.yaml` has nodes 2 and 3 commented out to match prod, so
> **uncomment both blocks first** (see
> [talos/SINGLE-NODE.md §3](talos/SINGLE-NODE.md)), run the DR drill, then
> re-comment them afterward to keep `talconfig.yaml` truthful about prod.
> Skipping this makes `task dr:apply-talos-configs` and
> `scripts/gen-dr-talconfig.sh` fail fast with a clear error rather than
> partially applying.

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

## Known issues & fixes

15 problems hit during real DR runs, each already fixed in the repo:
**[docs/dr-known-issues.md](docs/dr-known-issues.md)**.

⚠️ Read it before "simplifying" anything in the restore path that looks
redundant — one row documents a cleanup that silently broke two prod apps
for two days.

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
