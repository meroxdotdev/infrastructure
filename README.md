# merox.dev Infrastructure

Personal homelab running a 3-node Talos Kubernetes cluster on Proxmox, backed by an Oracle Cloud VPS for off-site services and S3 storage. Everything is declarative and GitOps-managed — a single `git push` is all it takes to deploy, update, or rebuild any part of the stack.

**What's here:** Flux manifests for the entire K8s cluster (media stack, observability, networking), Talos node configs, Ansible/Terraform for the VPS, and the tools to restore everything from scratch in about 50 minutes using only this repo and a backup of `age.key`.

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
| Uptime Kuma        | status.merox.dev                | Uptime monitoring + alerting                                        |
| Guacamole          | rmt.merox.dev                   | Remote desktop gateway (Authentik SSO)                              |
| Garage S3          | garage.cloud.merox.dev          | Off-site S3 storage — receives Longhorn volume backups from homelab |
| Netdata            | netdata.cloud.merox.dev         | Real-time metrics (parent + 3 child nodes)                          |
| Beszel             | beszel.cloud.merox.dev          | Host monitoring                                                     |
| Dozzle             | dozzle.cloud.merox.dev          | Docker log aggregation                                              |
| Glances            | glances.cloud.merox.dev         | System monitoring                                                   |
| OpenClaw Dashboard | agents.cloud.merox.dev          | AI agent control panel                                              |
| Code Server        | code.cloud.merox.dev            | Browser-based VS Code                                               |

### Kubernetes — on-premise (`kubernetes/` → Flux GitOps)

| Service              | Namespace     | Purpose                                                        |
| -------------------- | ------------- | -------------------------------------------------------------- |
| Jellyfin             | default       | Media server (Intel i915 GPU)                                  |
| Jellyseerr           | default       | Media request management                                       |
| Radarr / Sonarr      | default       | Movie / TV show automation                                     |
| Prowlarr             | default       | Torrent indexer                                                |
| qBittorrent          | default       | Torrent client (fixed IP: 10.57.57.102)                        |
| n8n                  | default       | Workflow automation                                            |
| Headlamp             | default       | Kubernetes dashboard (cluster-admin UI)                        |
| Authentik outpost    | default       | SSO proxy for K8s apps                                         |
| Portainer agent      | default       | Portainer agent (fixed IP: 10.57.57.103)                       |
| Prometheus + Grafana | observability | Metrics + dashboards                                           |
| Loki + Promtail      | observability | Log aggregation                                                |
| AlertManager         | observability | Alerts + healthchecks.io heartbeat                             |
| Longhorn             | storage       | Persistent volumes + off-site backup → Garage S3 on Oracle VPS |
| Cilium               | kube-system   | CNI + Gateway API + L2 LoadBalancer                            |
| cert-manager         | cert-manager  | Automated TLS certificates (ACME)                              |
| Cloudflare Tunnel    | network       | External exposure — zero open ports                            |
| k8s-gateway          | network       | Internal DNS for `*.merox.dev`                                 |

### Blog — Cloudflare Pages (private repo `meroxdotdev/merox`)

| Service   | URL       | Deploy                                |
| --------- | --------- | ------------------------------------- |
| merox.dev | merox.dev | Auto on `git push` via GitHub Actions |

### AI Agents — OpenClaw (`agent/` → `/home/openclaw/.openclaw/`)

| Agent        | Purpose                                 | Triggered by    |
| ------------ | --------------------------------------- | --------------- |
| news         | Daily briefing (HackerNews + RSS)       | Cron / Telegram |
| blog         | Publishes posts to merox.dev            | Telegram        |
| infra        | Runs kubectl / docker commands          | Telegram        |
| costs        | Infrastructure cost tracking            | Telegram        |
| design       | Visual content generation               | Telegram        |
| orchestrator | Routes between agents + scheduled tasks | Internal        |
| dashboard    | Updates agents.cloud.merox.dev          | Internal        |
| renovate     | Git dependency sync                     | Internal        |

---

## Where the code lives

| What                                       | GitHub repo                                                                 | Branch | Local path                              |
| ------------------------------------------ | --------------------------------------------------------------------------- | ------ | --------------------------------------- |
| K8s cluster (Flux manifests, Talos config) | [meroxdotdev/infrastructure](https://github.com/meroxdotdev/infrastructure) | `main` | `/srv/kubernetes/infrastructure/`       |
| Ansible + Terraform VPS DR                 | [meroxdotdev/infrastructure](https://github.com/meroxdotdev/infrastructure) | `main` | `/srv/kubernetes/infrastructure/vps/`   |
| Docker Compose VPS (raw files)             | [meroxdotdev/cloudlab-merox](https://github.com/meroxdotdev/cloudlab-merox) | `main` | `/srv/docker/oracle-cloud/`             |
| OpenClaw config template + infra skill     | [meroxdotdev/infrastructure](https://github.com/meroxdotdev/infrastructure) | `main` | `/srv/kubernetes/infrastructure/agent/` |
| Blog (Astro)                               | [meroxdotdev/merox](https://github.com/meroxdotdev/merox) _(private)_       | `main` | `/srv/merox/`                           |
| Agent runtime state (logs, memory)         | — not in Git —                                                              |        | `/home/openclaw/.openclaw/`             |

---

## Where secrets live

| Secret                                                     | Location                                       | Used by                       |
| ---------------------------------------------------------- | ---------------------------------------------- | ----------------------------- |
| K8s secrets (Cloudflare token, Authentik, Longhorn S3)     | SOPS/AGE → `*.sops.yaml` in repo               | Flux on apply                 |
| **`age.key`** ← **back this up**                           | `infrastructure/age.key` _(gitignored)_        | SOPS decryption               |
| VPS secrets (Tailscale key, Cloudflare, Authentik, Garage) | Ansible Vault → `vps/.../vault.yml`            | `make setup` / `make dr-full` |
| Pi-hole, Joplin DB, Code Server passwords                  | `/srv/docker/oracle-cloud/.env` _(gitignored)_ | Docker Compose                |
| Telegram token, Tavily API, Anthropic key                  | `/home/openclaw/.openclaw/.env` _(gitignored)_ | OpenClaw agents               |
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
| Anthropic / Claude | AI model for agents (OAuth)                                                                | Claude Pro                  |
| GitHub             | Repos + Actions (CI blog, Renovate)                                                        | Free                        |
| Let's Encrypt      | HTTPS certificates (auto-renew)                                                            | Free                        |
| Proxmox            | Hypervisor for K8s nodes                                                                   | Own hardware                |
| Synology DS223+    | Cold storage only (2026-07-23) — Photos/Drive/Docker decommissioned, no live services. Asleep except Sunday 02:50-03:40 (DSM Power Schedule + WoL), receiving a weekly versioned/deduped push from the R730xd | Own hardware (10.57.57.201) |

---

## Backup & off-site strategy

Everything declarative (K8s manifests, Ansible, Terraform, SOPS/vault secrets)
lives in this repo and is **not** backed up separately. Backups only cover
state that can't be rebuilt from git. **R730xd is the hub**: Longhorn (K8s
cluster data) now backs up nightly to a self-hosted Garage instance on the
R730xd itself (`proxmox/r730xd/`, not the VPS) — from there it fans out
on-prem to the Synology (cold clone) and off-site to Oracle Cloud (encrypted).
Separately, VPS → NAS still covers the VPS's own service state (DB dumps +
its own Garage instance, pulled nightly by the NAS). Observability history
and caches are deliberately not backed up — regenerable.

> **Canonical references**: VPS-side schedule —
> **[vps/roles/vps_backup/README.md](vps/roles/vps_backup/README.md)**;
> R730xd-side schedule — **[proxmox/r730xd/README.md](proxmox/r730xd/README.md)**.

**What an R730xd failure loses:** now the primary Longhorn backup target *and*
the K8s media/photos host, not just a hypervisor — see the "R730xd/Garage
total loss" runbook in [DR.md](DR.md) before treating this as equivalent to
the old VPS-hosted setup. The media library (`/media/library`) is treated as
replaceable "cattle" (re-downloadable) and deliberately has no second copy.
Immich's photo library (`/media/photos`) is backed by the weekly R730xd→
Synology push (see [proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs))
— the old pre-migration Synology copy was deleted 2026-07-23 once that push
was verified working; see [docs/immich-post-restore.md](docs/immich-post-restore.md)
for the restore procedure.
**What a VPS failure loses:** at most one day of its own service backups —
mirrored nightly to the NAS. Rebuild: `make dr-full` (~15 min),
`make dr-restore`, `task longhorn:restore`.

**Still manual (keep copies off this VPS):** `age.key`, `vps/.vault_pass`,
`~/.openclaw/.env`, `/srv/docker/oracle-cloud/.env`.

```bash
make backup-sync-now    # run extras backup + NAS sync immediately
make authentik-backup   # manual — run before any Authentik changes
```

---

## Full rebuild from scratch (~50 minutes)

> Detailed step-by-step guide: **[DEPLOY.md](DEPLOY.md)**

```
Prerequisites — have these ready:
  ✓ age.key (SOPS encryption key)
  ✓ Ansible Vault password
  ✓ Tailscale auth key (check it hasn't expired!)
  ✓ Cloudflare API token

Step 1 — VPS (~15 min)
  cd vps && make dr-full
  make dr-restore   # restore all data from NAS (DBs + extras, non-interactive)

Step 2 — Kubernetes (~20 min)
  cp /backup/age.key .
  # Edit: talos/talconfig.yaml (node IPs, install disk)
  # Edit: kubernetes/components/common/cluster-vars.yaml (LB IPs, NAS IP)
  task bootstrap:talos
  task bootstrap:apps
  task longhorn:restore

Step 3 — Agents (~15 min)
  sudo useradd -m openclaw && sudo usermod -aG docker openclaw
  sudo -u openclaw claude login   # Anthropic OAuth
  sudo -u openclaw openclaw onboard --mode local --auth-choice anthropic-cli
  # Fill in /home/openclaw/.openclaw/.env (Telegram token, Tavily key)
  systemctl --user enable --now openclaw-gateway

Validation:
  kubectl get nodes               # all Ready
  docker ps | wc -l               # ~16 containers
  curl -s https://agents.cloud.merox.dev  # dashboard reachable
  # Send Telegram message to bot → it replies
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  VPS (Oracle Cloud)   vps/                         │
│  ├── Traefik (reverse proxy + Cloudflare Tunnel)        │
│  ├── Pi-hole (DNS)                                      │
│  ├── Portainer EE (container management)                │
│  ├── Homepage (dashboard)                               │
│  ├── Joplin Server + Postgres (notes)                   │
│  ├── Uptime Kuma (monitoring)                           │
│  ├── Guacamole (remote desktop gateway)                 │
│  ├── Glances (system monitoring)                        │
│  └── Garage S3 (Longhorn backup target)                 │
└────────────────────┬────────────────────────────────────┘
                     │ Tailscale mesh VPN
┌────────────────────▼────────────────────────────────────┐
│  Kubernetes Cluster (Talos Linux + Flux)                │
│  ├── Cilium (CNI + Gateway API)                         │
│  ├── Longhorn (storage → backs up to Garage S3)         │
│  ├── cert-manager, external-dns, k8s-gateway            │
│  └── Apps: see kubernetes/apps/                         │
└─────────────────────────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│  OpenClaw — openclaw.ai                                 │
│  Telegram bot → Claude API → kubectl/docker             │
│  Config: agent/openclaw.json  Skill: agent/skills/infra │
└─────────────────────────────────────────────────────────┘
```

---

## Hardware

| Device                                     | Role                                                                                                                                                                                                | Specs                                       |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| Dell PowerEdge R730xd (`10.57.57.250`)     | Proxmox host — all 3 K8s control-plane VMs + Nvidia Quadro P2200 (Jellyfin transcoding, passthrough to controlplane-1). Also the K8s NFS server (`media` SAS ZFS pool, RAIDZ2): `/media/library` (Jellyfin/*arr), `/media/photos` (Immich), `/media/backups` (Longhorn/Garage/VM/Immich-DB backups), `/media/isos` | 2x Xeon E5-2630 v3, 251GB RAM, Quadro P2200 |
| Beelink GTi 13 Pro / px-0 (`10.57.57.254`) | Proxmox host — standby. Previously ran controlplane-1 with Intel iGPU passthrough (Jellyfin QSV); VM kept powered off, not deleted, as GPU-transcoding rollback path. See `docs/gpu-transcoding.md` | i9-13900H, 64GB, 2x2TB NVMe                 |
| Dell OptiPlex 3050 #1/#2 (px-1 / px-2)     | Retired — formerly Proxmox cluster members hosting controlplane-2/3, workloads consolidated onto the R730xd                                                                                         | i5-6500T, 16GB, 128GB NVMe                  |
| Dell PowerEdge R720                        | Proxmox Backup Server                                                                                                                                                                               | 2x Xeon E5-2697v2, 192GB                    |
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
├── agent/                      # OpenClaw config template + infra skill
│   ├── openclaw.json           # Gateway config (no secrets — use ~/.openclaw/.env)
│   └── skills/infra/           # kubectl/docker skill definition
├── DEPLOY.md                   # Full rebuild + DR guide
└── Taskfile.yaml               # Task runner (talosctl, flux, longhorn)
```

---

## Disaster Recovery

> **K8s cluster restore from S3 backups:** **[DR.md](DR.md)** (~35 min, tested end-to-end)
> Full rebuild from scratch (VPS + K8s + agents): **[DEPLOY.md](DEPLOY.md)**

| Scenario                                 | Action                                                                                    |
| ---------------------------------------- | ----------------------------------------------------------------------------------------- |
| **K8s cluster lost** (nodes dead)        | [DR.md](DR.md) — provision DR VMs, bootstrap, restore from S3                             |
| **VPS lost** (Oracle reclaims free tier) | `cd vps && make dr-full` → `make dr-restore` (~15 min)                                    |
| Full rebuild from scratch                | DEPLOY.md: Phase 1 (VPS) → Phase 2 (K8s) → Phase 3 (Agent)                                |
| New hardware (different IPs / disks)     | Edit `talos/talconfig.yaml`, `cluster-vars.yaml`, `cilium/networks.yaml`                  |
| Intel iGPU absent on new hardware        | Remove `gpu.intel.com/i915` from Jellyfin HelmRelease, disable intel-device-plugin        |
| Jellyfin streaming slow after restore    | [docs/jellyfin-post-restore.md](docs/jellyfin-post-restore.md) — manual UI steps required |
| Reinstall OpenClaw agents only           | DEPLOY.md Phase 3                                                                         |

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
