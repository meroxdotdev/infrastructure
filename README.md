# merox.dev Infrastructure

Single-node Talos Kubernetes cluster on Proxmox + an Oracle Cloud VPS for
off-site services. Declarative and GitOps-managed — `git push`
deploys, updates or rebuilds any part.

- **Contents** — Flux manifests (media stack, observability, networking),
  Talos node configs, Ansible/Terraform for the VPS, host runbooks.
- **Rebuild time** — ~35 min from scratch, needing only this repo,
  `age.key` and the restic password.
- **Start here** — this is the index. Everything else is linked from it.

---

## Everything at a glance

### VPS — Oracle Cloud (`vps/` → `make setup`)

| Service            | URL                             | Purpose                                                             |
| ------------------ | ------------------------------- | ------------------------------------------------------------------- |
| Traefik            | traefik.cloud.merox.dev         | Reverse proxy + ACME certs                                          |
| Pi-hole + Unbound  | pihole.cloud.merox.dev/admin    | DNS ad-blocking + DoH resolver                                      |
| Authentik          | sso.merox.dev                   | SSO / identity provider                                             |
| Portainer EE       | 100.72.22.38:9000 _(Tailscale)_ | Container management UI                                             |
| Homepage (private) | homepage.cloud.merox.dev _(Tailscale only)_ | Full dashboard — K8s, Proxmox, pfSense, Synology, Portainer         |
| Homepage (public)  | inside.merox.dev                | Curated overview, no credentials — bookmarks + anonymized stats     |
| Joplin Server      | joplin.cloud.merox.dev          | Notes sync (PostgreSQL backend)                                     |
| Guacamole          | rmt.merox.dev                   | Remote desktop gateway (Authentik SSO)                              |
| Garage S3          | _(not deployed on the VPS)_     | Real target is the R730xd LXC (see Hardware table below) — the VPS carries a Garage role too, kept only as a DR-only fallback, see [DR.md](DR.md#r730xd--garage-total-loss-fallback) |

### Kubernetes — on-premise (`kubernetes/` → Flux GitOps)

| Service              | Namespace     | Purpose                                                        |
| -------------------- | ------------- | -------------------------------------------------------------- |
| Jellyfin             | default       | Media server, personal, LAN/Tailscale only (Nvidia Quadro P2200 transcoding) |
| Jellyfin-public      | default       | Media server, curated 1080p library, internet-facing via the VPS — see [docs/jellyfin-public-exposure.md](docs/jellyfin-public-exposure.md) |
| Jellyseerr           | default       | Media request management                                       |
| Radarr / Sonarr      | default       | Movie / TV show automation                                     |
| Prowlarr             | default       | Torrent indexer                                                |
| qBittorrent          | default       | Torrent client (fixed IP: 10.57.57.102)                        |
| Immich               | default       | Photo/video library (photos.k8s.merox.dev) — replaces Synology Photos |
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
| netboot.xyz          | network       | PXE network boot menu for bare-metal installs                  |

### Blog — Cloudflare Pages (private repo `meroxdotdev/merox`)

| Service   | URL       | Deploy                                |
| --------- | --------- | ------------------------------------- |
| merox.dev | merox.dev | Auto on `git push` via GitHub Actions |

---

## Where the code lives

| What                                       | GitHub repo                                                                 | Branch | Local path                              |
| ------------------------------------------ | --------------------------------------------------------------------------- | ------ | --------------------------------------- |
| K8s cluster (Flux manifests, Talos config) | [meroxdotdev/infrastructure](https://github.com/meroxdotdev/infrastructure) | `main` | `/srv/kubernetes/infrastructure/`       |
| Ansible + Terraform VPS DR, incl. app-stack compose/Homepage config | [meroxdotdev/infrastructure](https://github.com/meroxdotdev/infrastructure) | `main` | `/srv/kubernetes/infrastructure/vps/`   |
| Blog (Astro)                               | [meroxdotdev/merox](https://github.com/meroxdotdev/merox) _(private)_       | `main` | `/srv/merox/`                           |

> Retired 2026-07-25: `meroxdotdev/cloudlab-merox`. Its docker-compose
> files now live in `vps/roles/app_stack_setup/files/app-stack/`.

---

## Where secrets live

| Secret                                                     | Location                                       | Used by                       |
| ---------------------------------------------------------- | ---------------------------------------------- | ----------------------------- |
| K8s secrets (Cloudflare token, Authentik, Longhorn S3)     | SOPS/AGE → `*.sops.yaml` in repo               | Flux on apply                 |
| **`age.key`** ← **back this up**                           | `infrastructure/age.key` _(gitignored)_        | SOPS decryption               |
| VPS secrets (Tailscale key, Cloudflare, Authentik, Garage) | Ansible Vault → `vps/.../vault.yml`            | `make setup` / `make dr-full` |
| Pi-hole, Joplin DB passwords                                | `/srv/docker/oracle-cloud/.env` _(gitignored)_ | Docker Compose                |
| Talos bootstrap secrets                                    | `talos/talsecret.sops.yaml` _(SOPS encrypted)_ | `task bootstrap:talos`        |
| **restic repo password** ← **unrecoverable**               | password manager, entry `restic bak password`  | offsite backup on Oracle      |

> **`age.key` and the restic password cannot be recovered from any
> backup.** Everything else is in the repo or restorable with one of those
> two.

- Lose `age.key` → no K8s secret decrypts.
- Lose the restic password → the Oracle backup is permanently unreadable.
  It protects the only repo that would hold a copy of itself, and the
  monthly drill can't catch a lost one — the drill runs on pve, where the
  password is present.
- Both are in the password manager. Keep a second copy somewhere that
  isn't a password manager.

---

## External dependencies

| Service            | Purpose                                                                                    | Cost                        |
| ------------------ | ------------------------------------------------------------------------------------------ | --------------------------- |
| Cloudflare         | DNS + Tunnel + Pages (blog)                                                                | Free                        |
| Tailscale          | Management VPN mesh                                                                        | Free                        |
| Oracle Cloud       | Primary VPS (4 vCPU ARM, 24GB)                                                             | Free tier                   |
| Hetzner            | Fallback VPS — only if Oracle Cloud free tier is lost. Provision on-demand: `make dr-full` | ~€7.85/mo if needed         |
| GitHub             | Repos + Actions (CI blog, Renovate)                                                        | Free                        |
| Let's Encrypt      | HTTPS certificates (auto-renew)                                                            | Free                        |
| Proxmox            | Hypervisor for K8s nodes                                                                   | Own hardware                |
| Synology DS223+    | Cold storage only (2026-07-23) — Photos/Drive/Docker decommissioned, no live services. Receiving a weekly versioned/deduped push from the R730xd | Own hardware (10.57.57.201) |

---

## Backup & off-site strategy

Rules:

- Anything declarative lives in this repo — never backed up separately.
- Backups cover only state that can't be rebuilt from git.
- Observability history and caches are regenerable — excluded.

```
Longhorn (K8s PVCs)      ──nightly──▶ ┐
Oracle VPS (state dumps) ──nightly──▶ │ R730xd  /media/backups
pfSense, VM dumps, docs  ──nightly──▶ ┘      │
                                    ┌────────┴────────┐
                                 weekly            nightly
                                    ▼                 ▼
                                Synology         Oracle (restic)
                             (cold, asleep)    (open format, drilled)
```

**Canonical detail — schedules, retention, every leg:**
[proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs) ·
[vps/roles/vps_backup/README.md](vps/roles/vps_backup/README.md) (VPS side)

| Failure | Loses | Recovery |
|---|---|---|
| R730xd | Longhorn backup target + media host, not just a hypervisor | [DR.md](DR.md#r730xd--garage-total-loss-fallback) |
| VPS | ≤1 night of its own service backups | `make dr-full` + `make dr-restore` (~15 min) |
| K8s cluster | Nothing that isn't in Git/Garage | `task bootstrap:apps` + `task longhorn:restore` |

Deliberately **not** covered: `/media/library` (movies/TV, re-downloadable).

**Still manual** (keep copies off the VPS): `age.key`, `vps/.vault_pass`,
`/srv/docker/oracle-cloud/.env`.

```bash
make backup-sync-now    # run extras backup + R730xd push immediately
make authentik-backup   # manual — run before any Authentik changes
```

---

## Full rebuild from scratch (~35 minutes)

Procedure: **[DEPLOY.md](DEPLOY.md)**. Have ready: `age.key`, the Ansible
Vault password, a Tailscale auth key (check it hasn't expired) and a
Cloudflare API token.

| Step | Command | Time |
|---|---|---|
| 1. VPS | `cd vps && make dr-full` → `make dr-restore` | ~15 min |
| 2. Kubernetes | `task bootstrap:talos` → `bootstrap:apps` → `longhorn:restore` | ~20 min |

Step 2 first needs `age.key` in place and new-hardware values edited into
`talos/talconfig.yaml` and `kubernetes/components/common/cluster-vars.yaml`
— see DEPLOY.md, which is the only place those edits are spelled out.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  R730xd (Proxmox host, 10.57.57.250) — the hub           │
│  ├── Kubernetes Cluster (Talos Linux + Flux, 1 CP VM)    │
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
│  ├── Guacamole (remote desktop gateway)                   │
│  └── nightly service-state push → R730xd                 │
└────────────────────┬─────────────────────────────────────┘
                     │ weekly relay          │ nightly restic
┌────────────────────▼──────────┐  ┌─────────▼──────────────┐
│  Synology (cold storage)      │  │  Oracle restic repo     │
│  fast local-ish recovery      │  │  (open format, no DSM)  │
└────────────────────────────────┘  └──────────────────────────┘
```

---

## Hardware

| Device                                     | Role                                                                                                                                                                                                | Specs                                       |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| Dell PowerEdge R730xd (`pve`, `10.57.57.250`) | Proxmox host + backup hub. 1 K8s control-plane VM (single-node since 2026-08-17, see [talos/SINGLE-NODE.md](talos/SINGLE-NODE.md)) · Quadro P2200 passthrough to controlplane-1 (Jellyfin) · `ollama` (alert triage) · `kali` (security testing, normally off) · NFS server for the `media` SAS pool · Garage LXC (Longhorn's S3 target). [REINSTALL](proxmox/r730xd/REINSTALL.md) | Xeon E5-2630 v4 (10C/20T, 1 socket), 251GB RAM (8x32GB DDR4 @ 1866), Quadro P2200 |
| Beelink GTi13 Ultra                        | Out of scope — hardware retained, powered off                                                                                                                                                       | i9-13900HK (14C/20T, 65W TDP), 64GB DDR5-5200 (2x32GB, max 96GB), 2x1TB NVMe (Crucial P3), dual 2.5GbE, PCIe 4.0 x8 slot |
| Dell OptiPlex 3050 #1/#2                   | Out of scope — hardware retained, powered off                                                                                                                                                       | i5-6500T, 32GB, 128GB NVMe (each)           |
| Synology DS223+                            | Cold storage only — see [proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs) for the weekly push mechanism and Power Schedule                                                     | 2x2TB HDD RAID1                             |
| XCY X44 (`fw`, `10.57.57.1`)               | pfSense — gateway, DHCP, Tailscale subnet router. [REINSTALL](pfsense/REINSTALL.md)                                                                                                                 | N100, 8GB                                   |
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
├── proxmox/
│   └── r730xd/                 # Backup hub: runbooks, cron scripts, /etc snapshots
├── pfsense/                    # Firewall runbook + its config-push script
├── docs/                       # operations, troubleshooting, post-restore guides
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
| **pve reinstalled** (host, not data)     | [proxmox/r730xd/REINSTALL.md](proxmox/r730xd/REINSTALL.md) — the `media` pool survives; import it, do not recreate |
| **pfSense lost** (gateway down)          | [pfsense/REINSTALL.md](pfsense/REINSTALL.md) — console access, not SSH. A config restore does **not** bring back its own backup script |
| Full rebuild from scratch                | DEPLOY.md: Phase 1 (VPS) → Phase 2 (K8s)                                                  |
| New hardware (different IPs / disks)     | Edit `talos/talconfig.yaml`, `cluster-vars.yaml`, `cilium/networks.yaml`                  |
| Nvidia GPU absent on new hardware        | Remove `runtimeClassName: nvidia` + `nvidia.com/gpu` limit from Jellyfin HelmRelease, disable nvidia-device-plugin |
| Jellyfin streaming slow after restore    | [docs/jellyfin-post-restore.md](docs/jellyfin-post-restore.md) — manual UI steps required |
| Immich photos/albums missing after restore | [docs/immich-post-restore.md](docs/immich-post-restore.md) — VectorChord extension + External Library re-scan |

**Total loss (fire, theft) — rebuild in this order.** Each layer needs the
one before it:

1. **pfSense** — no gateway, no internet, no restic. Console access; SSH
   won't be available. → [pfsense/REINSTALL.md](pfsense/REINSTALL.md)
2. **pve** — needs the restic password to pull `/root` back from Oracle.
   → [proxmox/r730xd/REINSTALL.md](proxmox/r730xd/REINSTALL.md)
3. **K8s** — on top of a working pve. → [DR.md](DR.md)

**VPS is independent** — on Oracle, needs nothing from home, rebuild any
time with `cd vps && make dr-full`.

---

## Operations & troubleshooting

Moved out of this page to keep it an index:

| Page | For |
|---|---|
| [docs/operations.md](docs/operations.md) | Day-to-day commands, Headlamp, VPS `make` targets, adding a node, Renovate, SOPS rotation |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Flux, HelmReleases, pods, Longhorn, disk swaps, unreachable nodes, Garage |
