# Disaster Recovery Runbook

Restore the full K8s cluster from Longhorn S3 backups onto fresh Talos nodes.

- **You need:** `age.key`, `talos/talsecret.sops.yaml` (or a full
  re-bootstrap), access to Proxmox.
- **In a hurry:** [`docs/dr-quickstart.md`](docs/dr-quickstart.md) — same
  procedure, commands only.
- **Rebuilding a host instead of the cluster:**
  [pve](proxmox/r730xd/REINSTALL.md) · [pfSense](pfsense/REINSTALL.md)

**Tested end-to-end:** 2026-08-29 on **px-0**, a different physical host —
71 min of prod downtime, prod VM stopped and restarted clean afterward.
Previously 2026-08-03 on pve/R730xd.

## Which host to target

**px-0 (Beelink)** — the real test. Different physical box, so it answers
"the R730xd died, can we recover?" and not just "did a recent change break
the restore?". 62GB RAM comfortably runs the single node at
`vm_memory_mb = 32768` — enough for every workload except the GPU ones.

**pve (R730xd)** — 238GB+ RAM free once prod is stopped, so it can match
prod exactly (`vm_memory_mb = 49152`). Use it only when px-0 is unavailable,
and note it cannot test host failure: the DR VMs land on the same box as
prod.

**What neither host tests:** anything that needs the Quadro P2200. On px-0,
`jellyfin`, `jellyfin-public` and `nvidia-device-plugin` stay down by
design — see step 8 of the quickstart.

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

> **No prerequisite edits.** DR provisions one node per MAC in
> `talos/terraform/terraform.tfvars`, and both that file and
> `talos/talconfig.yaml` default to prod's topology — one node since the
> 2026-08-17 downsize. Restoring what you actually run is the point.
>
> To exercise a 3-node restore instead, uncomment nodes 2 and 3 in
> `talconfig.yaml` (see
> [talos/SINGLE-NODE.md](talos/SINGLE-NODE.md#rollback-to-3-nodes)) and add
> their MACs/IPs to `terraform.tfvars`. `task dr:apply-talos-configs` refuses
> to run if the two counts disagree, so a half-done change fails fast instead
> of partially applying.

### Option A — Terraform (automated, recommended)

> **First time on this machine:** Terraform needs a Proxmox API token.
> Proxmox → Datacenter → API Tokens → Add (user `root@pam`, token name `terraform`,
> privilege separation OFF — secret shown once). Then:
> ```bash
> cp talos/terraform/terraform.tfvars.example talos/terraform/terraform.tfvars
> # fill in proxmox_token_id and proxmox_token_secret
> ```
>
> **Storage layout on pve:** `local-zfs` for `disk_storage`, `media-isos`
> for `iso_storage` — the `local` storage there only has content=snippets,
> no iso support. Working DR config: `proxmox_nodes = ["pve", "pve", "pve"]`.

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
3. Creates restore Volume CRDs for every volume in `restore-all-volumes` —
   currently 10: `jellyfin`, `prowlarr`, `radarr`, `sonarr`, `jellyseerr`,
   `qbittorrent`, `immich-postgres`, `n8n`, and both Immich libraries
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
- `jellyfin` → Pending: DR VMs have no Nvidia GPU (`nvidia.com/gpu`). Jellyfin runs but hardware transcoding unavailable. Fix: patch Jellyfin HelmRelease to remove the GPU resource request and `runtimeClassName: nvidia`.
- Prometheus/Loki/Grafana/Netdata start with empty volumes — metrics/logs history is deliberately not backed up. Grafana dashboards come from git (sidecar provisioning).

---

## Phase 6 — Cleanup or failback

```bash
# Destroy DR VMs after test (or when ready to fail back to prod)
task dr:destroy-vms

# Restart the prod node via Proxmox UI:
# VM 800 → kubernetes-controlplane-1 (pve / R730xd) - the only control-plane
# VM since the 2026-08-17 single-node downsize (see talos/SINGLE-NODE.md).
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

⚠️ `/media/photos` is a **stale leftover**, not live Immich data. No longer
NFS-exported (its only consumer, Filebrowser, was removed), but the weekly
Synology and nightly restic legs still copy it directly from disk. Fine as
a second safety net — do not treat it as current.

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
new LXC on `pve`, or the VPS temporarily — with the recovered
`data`/`meta` bind-mounted in. Reuse `vps/roles/garage_setup`, setting
`garage_webui_enabled` per host, same as
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
