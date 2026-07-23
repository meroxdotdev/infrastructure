# merox.dev Infrastructure

Personal homelab running a 3-node Talos Kubernetes cluster on Proxmox, backed by an Oracle Cloud VPS for off-site services and S3 storage. Everything is declarative and GitOps-managed — a single `git push` is all it takes to deploy, update, or rebuild any part of the stack.

**What's here:** Flux manifests for the entire K8s cluster (media stack, observability, networking), Talos node configs, Ansible/Terraform for the VPS, and the tools to restore everything from scratch in about 35 minutes using only this repo and a backup of `age.key`.

**Single reference document** — if you don't know where to look, start here.

---

## Everything at a glance

### VPS — Oracle Cloud (`vps/` → `make setup`)

| Service            | URL                             | Purpose                                                             |
| ------------------ | ------------------------------- | ------------------------------------------------------------------- |
| Traefik            | traefik.cloud.merox.dev         | Reverse proxy + ACME certs                                          |
| Pi-hole + Unbound  | pihole.cloud.merox.dev/admin    | DNS ad-blocking + DoH resolver                                      |
| Authentik          | sso.merox.dev                   | SSO / identity provider                                             |
| Portainer EE       | 100.72.22.38:9000 _(Tailscale)_ | Container management UI                                             |
| Homepage           | inside.merox.dev _(Tailscale)_  | Internal dashboard (K8s + Proxmox + router)                         |
| Joplin Server      | joplin.cloud.merox.dev          | Notes sync (PostgreSQL backend)                                     |
| Guacamole          | rmt.merox.dev                   | Remote desktop gateway (Authentik SSO)                              |
| Garage S3          | garage.cloud.merox.dev          | Rollback safety net only — Longhorn's real target is now on R730xd, see below |
| Netdata            | netdata.cloud.merox.dev         | Real-time metrics (parent + 3 child nodes)                          |
| Beszel             | beszel.cloud.merox.dev          | Host monitoring                                                     |
| Dozzle             | dozzle.cloud.merox.dev          | Docker log aggregation                                              |
| Glances            | glances.cloud.merox.dev         | System monitoring                                                   |
| Code Server        | code.cloud.merox.dev            | Browser-based VS Code                                               |

### Kubernetes — on-premise (`kubernetes/` → Flux GitOps)

| Service              | Namespace     | Purpose                                                        |
| -------------------- | ------------- | -------------------------------------------------------------- |
| Jellyfin             | default       | Media server (Nvidia Quadro P2200 transcoding)                  |
| Jellyseerr           | default       | Media request management                                       |
| Radarr / Sonarr      | default       | Movie / TV show automation                                     |
| Prowlarr             | default       | Torrent indexer                                                |
| qBittorrent          | default       | Torrent client (fixed IP: 10.57.57.102)                        |
| Immich               | default       | Photo/video library (photos.k8s.merox.dev) — replaces Synology Photos |
| Filebrowser          | default       | Web browser for the R730xd SAS pool (files.k8s.merox.dev), incl. WebDAV |
| n8n                  | default       | Workflow automation                                            |
| Headlamp             | default       | Kubernetes dashboard (cluster-admin UI)                        |
| Authentik outpost    | default       | SSO proxy for K8s apps                                         |
| Portainer agent      | default       | Portainer agent (fixed IP: 10.57.57.103)                       |
| Prometheus + Grafana | observability | Metrics + dashboards                                           |
| Loki + Promtail      | observability | Log aggregation                                                |
| AlertManager         | observability | Alerts + healthchecks.io heartbeat                             |
| Longhorn             | storage       | Persistent volumes + off-site backup → Garage S3 on R730xd     |
| Cilium               | kube-system   | CNI + Gateway API + L2 LoadBalancer                            |
| cert-manager         | cert-manager  | Automated TLS certificates (ACME)                              |
| Cloudflare Tunnel    | network       | External exposure — zero open ports                            |
| k8s-gateway          | network       | Internal DNS for `*.merox.dev`                                 |

### Blog — Cloudflare Pages (private repo `meroxdotdev/merox`)

| Service   | URL       | Deploy                                |
| --------- | --------- | ------------------------------------- |
| merox.dev | merox.dev | Auto on `git push` via GitHub Actions |

---

## Where the code lives

| What                                       | GitHub repo                                                                 | Branch | Local path                              |
| ------------------------------------------ | --------------------------------------------------------------------------- | ------ | --------------------------------------- |
| K8s cluster (Flux manifests, Talos config) | [meroxdotdev/infrastructure](https://github.com/meroxdotdev/infrastructure) | `main` | `/srv/kubernetes/infrastructure/`       |
| Ansible + Terraform VPS DR                 | [meroxdotdev/infrastructure](https://github.com/meroxdotdev/infrastructure) | `main` | `/srv/kubernetes/infrastructure/vps/`   |
| Docker Compose VPS (raw files)             | [meroxdotdev/cloudlab-merox](https://github.com/meroxdotdev/cloudlab-merox) | `main` | `/srv/docker/oracle-cloud/`             |
| Blog (Astro)                               | [meroxdotdev/merox](https://github.com/meroxdotdev/merox) _(private)_       | `main` | `/srv/merox/`                           |

---

## Where secrets live

| Secret                                                     | Location                                       | Used by                       |
| ---------------------------------------------------------- | ---------------------------------------------- | ----------------------------- |
| K8s secrets (Cloudflare token, Authentik, Longhorn S3)     | SOPS/AGE → `*.sops.yaml` in repo               | Flux on apply                 |
| **`age.key`** ← **back this up**                           | `infrastructure/age.key` _(gitignored)_        | SOPS decryption               |
| VPS secrets (Tailscale key, Cloudflare, Authentik, Garage) | Ansible Vault → `vps/.../vault.yml`            | `make setup` / `make dr-full` |
| Pi-hole, Joplin DB, Code Server passwords                  | `/srv/docker/oracle-cloud/.env` _(gitignored)_ | Docker Compose                |
| Talos bootstrap secrets                                    | `talos/talsecret.sops.yaml` _(SOPS encrypted)_ | `task bootstrap:talos`        |

> **If you lose `age.key`, you cannot decrypt any K8s secret. Back it up separately.**

---

## External dependencies

| Service            | Purpose                                                                                    | Cost                        |
| ------------------ | ------------------------------------------------------------------------------------------ | --------------------------- |
| Cloudflare         | DNS + Tunnel + Pages (blog)                                                                | Free                        |
| Tailscale          | Management VPN mesh                                                                        | Free                        |
| Oracle Cloud       | Primary VPS (4 vCPU ARM, 24GB)                                                             | Free tier                   |
| Hetzner            | Fallback VPS — only if Oracle Cloud free tier is lost. Provision on-demand: `make dr-full` | ~€5.39/mo if needed         |
| GitHub             | Repos + Actions (CI blog, Renovate)                                                        | Free                        |
| Let's Encrypt      | HTTPS certificates (auto-renew)                                                            | Free                        |
| Proxmox            | Hypervisor for K8s nodes                                                                   | Own hardware                |
| Synology DS223+    | Cold storage only (2026-07-23) — Photos/Drive/Docker decommissioned, no live services. Asleep except Sunday 02:50-03:40 (DSM Power Schedule + WoL), receiving a weekly versioned/deduped push from the R730xd | Own hardware (10.57.57.201) |

---

## Backup & off-site strategy

Everything declarative (K8s manifests, Ansible, Terraform, SOPS/vault secrets)
lives in this repo and is **not** backed up separately. Backups only cover
state that can't be rebuilt from git. **R730xd is the hub**: Longhorn (K8s
cluster data) backs up nightly to a self-hosted Garage instance on R730xd
itself (`proxmox/r730xd/`, not the VPS — moved there 2026-07-21), alongside
photos, documents, VM backups, pfSense config, and the Oracle VPS's own
nightly service-state push (Authentik/Joplin/Guacamole/Traefik/Pi-hole/
Homepage/Portainer — rerouted through R730xd 2026-07-23, no longer straight
to Synology). From R730xd, one weekly push (Sunday) relays all of that to
Synology (cold storage, asleep except during the push window), and Synology
relays the same set onward to Oracle Cloud via Hyper Backup — closing the
loop back to where the VPS backup originated. Observability history and
caches are deliberately not backed up — regenerable.

> **Canonical references**: VPS-side schedule —
> **[vps/roles/vps_backup/README.md](vps/roles/vps_backup/README.md)**;
> R730xd-side schedule (incl. the Synology + Oracle legs) —
> **[proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs)**.

**What an R730xd failure loses:** the primary Longhorn backup target *and*
the K8s media/photos host, not just a hypervisor — see the "R730xd/Garage
total loss" runbook in [DR.md](DR.md) before treating this as equivalent to
the old VPS-hosted setup. The media library (`/media/library`) is treated as
replaceable "cattle" (re-downloadable) and deliberately has no second copy.
Immich's photo library (`/media/photos`) is covered by the same weekly
R730xd→Synology→Oracle chain; see
[docs/immich-post-restore.md](docs/immich-post-restore.md) for the restore
procedure.
**What a VPS failure loses:** at most one night of its own service backups —
pushed nightly to R730xd, from which it rides the same weekly relay above.
Rebuild: `make dr-full` (~15 min), `make dr-restore`, `task longhorn:restore`.

**Still manual (keep copies off this VPS):** `age.key`, `vps/.vault_pass`,
`/srv/docker/oracle-cloud/.env`.

```bash
make backup-sync-now    # run extras backup + R730xd push immediately
make authentik-backup   # manual — run before any Authentik changes
```

---

## Full rebuild from scratch (~35 minutes)

> Detailed step-by-step guide: **[DEPLOY.md](DEPLOY.md)**

```
Prerequisites — have these ready:
  ✓ age.key (SOPS encryption key)
  ✓ Ansible Vault password
  ✓ Tailscale auth key (check it hasn't expired!)
  ✓ Cloudflare API token

Step 1 — VPS (~15 min)
  cd vps && make dr-full
  make dr-restore   # restore all data from R730xd (DBs + extras, non-interactive)

Step 2 — Kubernetes (~20 min)
  cp /backup/age.key .
  # Edit: talos/talconfig.yaml (node IPs, install disk)
  # Edit: kubernetes/components/common/cluster-vars.yaml (LB IPs, R730xd IP)
  task bootstrap:talos
  task bootstrap:apps
  task longhorn:restore

Validation:
  kubectl get nodes               # all Ready
  docker ps | wc -l               # ~14 containers
  kubectl get pods -A | grep -v Running   # should be empty (+ Completed jobs)
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  R730xd (Proxmox host, 10.57.57.250) — the hub           │
│  ├── Kubernetes Cluster (Talos Linux + Flux, 3 CP VMs)   │
│  │   ├── Cilium (CNI + Gateway API)                      │
│  │   ├── Longhorn (storage → backs up to Garage LXC)     │
│  │   ├── cert-manager, k8s-gateway                       │
│  │   └── Apps: see kubernetes/apps/                      │
│  ├── Garage S3 (LXC 103 — Longhorn's backup target)      │
│  └── NFS: media/photos/backups (SAS ZFS pool, RAIDZ2)    │
└────────────────────┬─────────────────────────────────────┘
                     │ Tailscale mesh VPN
┌────────────────────▼─────────────────────────────────────┐
│  VPS (Oracle Cloud)   vps/                                │
│  ├── Traefik (reverse proxy + Cloudflare Tunnel)          │
│  ├── Pi-hole (DNS), Portainer EE, Homepage                │
│  ├── Joplin Server + Postgres (notes)                     │
│  ├── Guacamole (remote desktop gateway), Glances          │
│  └── nightly service-state push → R730xd                 │
└────────────────────┬─────────────────────────────────────┘
                     │ weekly relay
┌────────────────────▼─────────────────────────────────────┐
│  Synology (cold storage) → Oracle Hyper Backup (offsite)  │
└────────────────────────────────────────────────────────────┘
```

---

## Hardware

| Device                                     | Role                                                                                                                                                                                                | Specs                                       |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| Dell PowerEdge R730xd (`10.57.57.250`)     | Proxmox host — **controlplane-1 only** (not all 3 — see note below) + Nvidia Quadro P2200 (Jellyfin transcoding, passthrough to controlplane-1). Also the K8s NFS server (`media` SAS ZFS pool, RAIDZ2): `/media/library` (Jellyfin/*arr), `/media/photos` (Immich), `/media/backups` (Longhorn/Garage/VM/Immich-DB backups), `/media/isos`, and the Garage LXC (Longhorn's S3 backup target) | 2x Xeon E5-2630 v3, 251GB RAM, Quadro P2200 |
| Beelink GTi 13 Pro / px-0 (`10.57.57.254`) | Proxmox host — **controlplane-2 and controlplane-3**, plus the Proxmox Datacenter Manager appliance VM (links `pve`+`px-0` without a corosync cluster). Not standby — actively runs 2 of the 3 K8s control-plane nodes | i9-13900H, 64GB, 2x2TB NVMe                 |
| Dell OptiPlex 3050 #1/#2 (px-1 / px-2)     | Retired — formerly Proxmox cluster members hosting controlplane-2/3 before that role moved to px-0 (not the R730xd)                                                                                 | i5-6500T, 16GB, 128GB NVMe                  |
| Synology DS223+                            | Cold storage only — see [proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs) for the weekly push mechanism and Power Schedule                                                     | 2x2TB HDD RAID1                             |
| XCY X44                                    | pfSense Firewall                                                                                                                                                                                    | N100, 8GB                                   |
| Oracle Cloud ARM VPS                       | Off-site services (primary)                                                                                                                                                                         | 4 vCPU ARM, 24GB RAM, 200GB                 |

---

## Repository layout

```
infrastructure/
├── vps/    # Ansible — VPS provisioning + Terraform DR
├── kubernetes/
│   ├── apps/                   # Flux app manifests (namespaced)
│   ├── flux/                   # Flux bootstrap + HelmRepositories
│   └── components/             # Shared Kustomize components (common, repos)
├── talos/                      # Talos node configs + patches
├── bootstrap/                  # Cluster bootstrap helmfile
├── proxmox/r730xd/             # R730xd backup hub docs (Garage, NFS exports, downstream relays)
├── DEPLOY.md                   # Full rebuild + DR guide
└── Taskfile.yaml               # Task runner (talosctl, flux, longhorn)
```

---

## Disaster Recovery

> **K8s cluster restore from S3 backups:** **[DR.md](DR.md)** (~35 min, tested end-to-end)
> Full rebuild from scratch (VPS + K8s): **[DEPLOY.md](DEPLOY.md)**

| Scenario                                 | Action                                                                                    |
| ---------------------------------------- | ----------------------------------------------------------------------------------------- |
| **K8s cluster lost** (nodes dead)        | [DR.md](DR.md) — provision DR VMs, bootstrap, restore from S3                             |
| **VPS lost** (Oracle reclaims free tier) | `cd vps && make dr-full` → `make dr-restore` (~15 min)                                    |
| **R730xd lost** (hardware failure)       | [DR.md "R730xd/Garage total loss fallback"](DR.md#r730xd--garage-total-loss-fallback) — rebuild Garage from Synology/Oracle copy, repoint Longhorn, `task longhorn:restore` |
| Full rebuild from scratch                | DEPLOY.md: Phase 1 (VPS) → Phase 2 (K8s)                                                  |
| New hardware (different IPs / disks)     | Edit `talos/talconfig.yaml`, `cluster-vars.yaml`, `cilium/networks.yaml`                  |
| Intel iGPU absent on new hardware        | Remove `gpu.intel.com/i915` from Jellyfin HelmRelease, disable intel-device-plugin        |
| Jellyfin streaming slow after restore    | [docs/jellyfin-post-restore.md](docs/jellyfin-post-restore.md) — manual UI steps required |
| Immich photos/albums missing after restore | [docs/immich-post-restore.md](docs/immich-post-restore.md) — VectorChord extension + External Library re-scan |

---

## Day-to-day operations

### Cluster

```bash
kubectl get nodes
kubectl get kustomizations -A
kubectl get helmreleases -A
cilium status

task reconcile                              # force Flux sync

task talos:generate-config                  # after editing talconfig.yaml
task talos:apply-node IP=10.57.57.80        # apply config to a node
task talos:upgrade-node IP=10.57.57.80      # upgrade Talos on a node
task talos:upgrade-k8s                      # upgrade Kubernetes version
```

### Headlamp (K8s dashboard)

UI at `https://headlamp.k8s.merox.dev` (internal gateway only). Login uses a bearer
token for the `headlamp` ServiceAccount (bound to `cluster-admin` via the
`headlamp-admin` ClusterRoleBinding). Generate a new one when the old token expires
or gets invalidated:

```bash
kubectl create token headlamp -n default --duration=8760h
```

Run this directly in your terminal (not copy-pasted through a chat/markdown UI —
hidden characters in the clipboard can corrupt the cookie and cause
"Error authenticating").

### VPS

```bash
cd vps/

make health-check       # verify all services are running
make setup              # full redeploy (idempotent)
make update             # OS package updates only
make check              # dry-run (--check --diff)
make restore            # interactive restore wizard (Joplin / Authentik / all)
make cleanup            # remove unused Docker images/volumes
make dr-full            # provision fallback VPS + cloud-init deploys everything (~15 min)
```

---

## Troubleshooting

### Flux not reconciling

```bash
flux get sources git -A
flux get kustomizations -A
flux logs --level=error
flux reconcile kustomization cluster-apps --with-source
```

### HelmRelease stuck / failed

```bash
kubectl get helmreleases -A | grep -v True
flux logs --kind HelmRelease --name <name> -n <namespace>
flux reconcile helmrelease <name> -n <namespace> --with-source
# If Helm refuses changes — suspend + resume:
flux suspend helmrelease <name> -n <namespace>
flux resume helmrelease <name> -n <namespace>
```

### Pod issues

```bash
kubectl -n <namespace> get pods -o wide
kubectl -n <namespace> describe pod <pod>
kubectl -n <namespace> logs <pod> -f
kubectl -n <namespace> logs <pod> --previous
kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
```

### Longhorn storage

```bash
kubectl -n longhorn-system get volumes
kubectl -n longhorn-system get nodes.longhorn.io

# Remove orphaned replicas (safe)
kubectl get orphan -n longhorn-system -o name | \
  xargs kubectl delete -n longhorn-system
```

### Replacing a disk on a K8s node

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# Proxmox: shut down VM, swap physical disk, start VM
task talos:generate-config
talosctl apply-config --insecure --nodes <ip> \
  --file talos/clusterconfig/<node>.yaml
kubectl uncordon <node>
# If Longhorn disk UUID changed → evict replicas via UI, re-add new disk
```

> Wait 1-2 hours between disk swaps to allow replica rebuild.

### Node unreachable

```bash
talosctl -n <node-ip> health
talosctl -n <node-ip> dmesg
talosctl -n <node-ip> services
kubectl describe node <node-name>
```

### Garage S3

```bash
docker exec garage /garage status
docker exec garage /garage bucket list
kubectl -n longhorn-system get secret minio-secret
```

---

## Maintenance

### Adding a node

```bash
# Keep an odd number of control-plane nodes (1, 3, 5) for quorum
talosctl get disks -n <new-node-ip> --insecure    # find the install disk
talosctl get links -n <new-node-ip> --insecure    # find the MAC address
# Add entry to talos/talconfig.yaml with disk + MAC
task talos:generate-config
task talos:apply-node IP=<new-node-ip>
kubectl get nodes --watch
```

### Automatic updates (Renovate)

Renovate runs every weekend and opens PRs automatically for:

- Helm chart versions (all HelmReleases)
- Container image tags (annotated with `# renovate:`)
- Talos / Kubernetes versions (`.mise.toml`)

Config: `.renovaterc.json5`

### SOPS secret rotation

```bash
sops kubernetes/apps/<namespace>/<app>/app/secret.sops.yaml
# After rotating the AGE key:
find . -name "*.sops.*" -exec sops updatekeys {} \;
```

### Security

- Kubernetes secrets: SOPS/AGE encrypted (back up `age.key` separately — it's critical)
- Ansible secrets: encrypted Vault (`vps/`)
- All traffic: Tailscale mesh or Cloudflare Tunnel (zero open ports)
