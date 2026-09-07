# merox.dev Infrastructure

Three-node Talos Kubernetes cluster, one node per physical machine — a Beelink
mini PC, a Dell R730xd that also holds the storage, and an OptiPlex — plus an
Oracle Cloud VPS for off-site services. Everything is declarative and
GitOps-managed: `git push` deploys, updates or rebuilds any part.

Rebuild from nothing takes ~35 minutes and needs three things — this repo,
`age.key`, and the restic password.

**This page is the index.** Anything with real detail lives behind a link.

## The whole thing, in six lines

Read this first if it has been a while.

| | |
|---|---|
| **Network** | pfSense routes and hands out addresses. Tailscale is the only way in from outside and nothing is port-forwarded; what is public reaches the internet through an outbound-only Cloudflare tunnel. |
| **Compute** | Three Proxmox hosts, standalone rather than clustered — joined through Proxmox Datacenter Manager, never corosync. Each runs exactly one Kubernetes node, so the three etcd votes sit in three chassis and losing any one machine leaves a quorum: `pve-1` (Beelink) holds `kubernetes-1` with its iGPU passed through for transcoding, `pve-2` (R730xd) holds `kubernetes-2` alongside the disks, `pve-3` (OptiPlex) holds `kubernetes-3` on a raw Intel SSD. Drilled by pulling `pve-1`'s power — [what survived and what did not](talos/THREE-NODE.md). Flux reconciles the cluster from this repo, so a push is the deploy. |
| **Storage** | ZFS. `media` is twelve SAS disks in two raidz2 vdevs, holds bulk and spins down when idle; `rpool` is a mirrored SSD pair holding anything an application touches during the day. |
| **Backup** | Every source writes into `/media/backups/` on pve-2. From there restic pushes to Oracle nightly and the Synology pulls a plain-file copy weekly. Since 2026-09-07 pve-2 can add to both and delete from neither: the Oracle repository is served append-only and the NAS holds no credential pve-2 can use, so retention runs on each target rather than on the host being backed up. Only what cannot be rebuilt is kept — the tiers are in [`docs/architecture.md`](docs/architecture.md). |
| **Off-site** | An Oracle Cloud VPS runs what should outlive the house: Authentik SSO, Traefik, Pi-hole, Joplin, Guacamole, Homepage. It depends on nothing at home, pushes its own state to pve-2 nightly, and is rebuilt with `cd vps && make dr-full`. Tailscale is what joins the two sites. |
| **Public edge** | A second, stateless Oracle instance in Frankfurt (`edge-fra`) terminates TLS for the public Jellyfin only — 30 ms to viewers instead of 165 ms from Phoenix. Borrowed tenancy, no state, `cd vps && make edge-setup`. [Design](docs/jellyfin-public-exposure.md). |
| **Recovery** | [`docs/dr-quickstart.md`](docs/dr-quickstart.md) — eight `task` commands, drilled on separate hardware. `age.key` and the restic password cannot be recreated; everything else can. |

Every scheduled job reports to healthchecks.io, so silence is the alarm.
`nightly-checks.sh` on pve-2 also compares the host against this repo and fails
if they have drifted apart.

## Everything at a glance

### VPS — Oracle Cloud (`vps/` → `make setup`)

| Service | URL | Purpose |
|---|---|---|
| Traefik | traefik.cloud.merox.dev | Reverse proxy + ACME certs |
| Pi-hole + Unbound | pihole.cloud.merox.dev/admin | DNS ad-blocking + DoH resolver |
| Authentik | sso.merox.dev | SSO / identity provider |
| Portainer EE | portainer.cloud.merox.dev · 100.72.22.38:9000 _(Tailscale)_ | Container management UI for Docker on the VPS. Its Kubernetes agent was removed on 2026-09-07 — it held a standing `cluster-admin`, and Flux is the only thing that should write to the cluster |
| Homepage | homepage.cloud.merox.dev _(Tailscale)_ · inside.merox.dev _(public, curated)_ | Dashboards |
| Joplin Server | joplin.cloud.merox.dev | Notes sync (PostgreSQL) |
| Guacamole | rmt.merox.dev | Remote desktop gateway (Authentik SSO) |

### Public edge — Oracle Cloud Frankfurt (`vps/` → `make edge-setup`)

| Service | URL | Purpose |
|---|---|---|
| Traefik (edge) | studio.merox.dev | The only public listener: TLS for the public Jellyfin, geoblocked in kernel |

### Kubernetes — on-premise (`kubernetes/` → Flux GitOps)

| Service | Namespace | Purpose |
|---|---|---|
| Jellyfin | default | Media server, LAN/Tailscale only (Intel QuickSync on pve-1) |
| Jellyfin-public | default | Curated 1080p library, internet-facing — [how](docs/jellyfin-public-exposure.md) |
| Jellyseerr · Radarr · Sonarr · Prowlarr · qBittorrent | default | Media requests, automation, indexing, download |
| Immich | default | Photo/video library (photos.k8s.merox.dev) |
| n8n | default | Workflow automation. No longer in the alerting path — Alertmanager and Flux both speak Telegram natively and now do, since 2026-09-07 |
| Headlamp | default | Kubernetes dashboard |
| Authentik outpost | default | SSO proxy |
| Prometheus + Grafana · Loki + Promtail · AlertManager | observability | Metrics, logs, alerts |
| Longhorn | storage | Persistent volumes, backed up to the Garage S3 LXC |
| Cilium | kube-system | CNI + Gateway API + L2 LoadBalancer |
| cert-manager | cert-manager | Automated TLS |
| Cloudflare Tunnel · k8s-gateway · netboot.xyz | network | External exposure with zero open ports · internal DNS · PXE boot |

The blog (`merox.dev`) is a separate private repo, `meroxdotdev/merox`,
deployed to Cloudflare Pages on push.

## Two secrets you cannot lose

Everything else is in this repo or restorable with one of these.

| Secret | Where | Losing it means |
|---|---|---|
| `age.key` | `infrastructure/age.key`, gitignored, + password manager | No K8s secret decrypts |
| restic repo password | password manager, entry `restic bak password` | The Oracle backup is permanently unreadable |

Neither is recoverable from any backup — the restic password protects the only
repo that would hold a copy of it. Keep a second copy somewhere that is not a
password manager.

Other secrets, all reproducible: K8s secrets via SOPS/AGE (`*.sops.yaml`), VPS
secrets in Ansible Vault (`vps/.../vault.yml`), Talos bootstrap in
`talos/talsecret.sops.yaml`, Pi-hole/Joplin passwords in
`/srv/docker/oracle-cloud/.env`. Keep `vps/.vault_pass` and that `.env` copied
off the VPS.

## Hardware

| Device | Role | Specs |
|---|---|---|
| Dell R730xd — `pve-2`, `10.57.57.250` | Storage and backup host: the media array and its NFS exports, the Garage S3 LXC Longhorn backs into, the Nextcloud VM, and every backup leg. Also runs `kubernetes-2` (VM 811) — its mirrored `rpool` is the middle etcd disk. [Runbook](proxmox/pve-2/README.md) · [Reinstall](proxmox/pve-2/REINSTALL.md) | Xeon E5-2630 v4 (10C/20T), 251GB DDR4, Quadro P2200 (in the chassis but unused, 3.86 W idle) |
| XCY X44 — `fw`, `10.57.57.1` | pfSense: gateway, DHCP, Tailscale subnet router. [Reinstall](pfsense/REINSTALL.md) | N100, 8GB |
| Oracle Cloud ARM VPS — `vps01`, us-phoenix-1 | Off-site services | 4 vCPU ARM, 24GB, 200GB |
| Oracle Cloud ARM VPS — `edge-fra`, eu-frankfurt-1 | Public TLS edge, borrowed tenancy | 2 vCPU ARM, 12GB, 45GB |
| Synology DS223+ — `10.57.57.201` | Cold storage. **Pulls** weekly from pve-2 over two `rrsync -ro` keys rather than being pushed to, so pve-2 cannot reach it — [runbook](synology/README.md) | 2x2TB RAID1 |
| Beelink GTi13 Ultra — `pve-1`, `10.57.57.254` | Runs `kubernetes-1` (VM 810, 14 cores / 32 GiB / 350 GB, Iris Xe passed through) — the only node with a GPU, so hardware transcoding lives and dies with this box. [Runbook](proxmox/pve-1/README.md) | i9-13900HK, 64GB DDR5, 2x1TB NVMe (QLC). The 2.5 GbE ports negotiate at 1 GbE — the switch is the ceiling |
| Dell OptiPlex 3050 — `pve-3`, `10.57.57.253` | Third Proxmox host, standalone. Prepared 2026-09-04: freed from a dead corosync cluster, renamed, stripped to one storage. Runs `kubernetes-3` (VM 812) and the PDM container. [Runbook](proxmox/pve-3/README.md) | i5-6500T (4C/4T), 32GB DDR4, 120GB ADATA NVMe (system, plus the PDM container) + 960GB Intel D3-S4510 SATA with power-loss protection, passed raw into VM 812 — the best etcd disk in the fleet |
| Dell OptiPlex 3050 (second unit) | Cold spare, powered off | i5-6500T, 32GB |

## Where to go

| I want to | Page |
|---|---|
| Rebuild everything from scratch | [DEPLOY.md](DEPLOY.md) — VPS first, then Kubernetes |
| Recover the cluster | [DR.md](DR.md) · [quickstart](docs/dr-quickstart.md) — eight commands |
| Understand the backups | [proxmox/pve-2/README.md](proxmox/pve-2/README.md) — every leg, schedule, retention |
| Run day-to-day things | [docs/operations.md](docs/operations.md) |
| Fix something broken | [docs/troubleshooting.md](docs/troubleshooting.md) · [DR known issues](docs/dr-known-issues.md) |
| Know what the code is | `kubernetes/` Flux manifests · `talos/` node configs · `vps/` Ansible + Terraform · `proxmox/` and `pfsense/` host runbooks |

**Total loss (fire, theft) — rebuild in this order**, because each layer needs
the one before it: pfSense (no gateway, no internet, no restic — console
access only) → pve-2 (needs the restic password to pull `/root` back from
Oracle) → Kubernetes. The VPS is independent of all three: `cd vps && make
dr-full`, any time.

## External dependencies

| Service | Purpose | Cost |
|---|---|---|
| Cloudflare | DNS, Tunnel, Pages | Free |
| Tailscale | Management VPN mesh | Free |
| Oracle Cloud | Primary VPS, plus a borrowed tenancy for the Frankfurt edge | Free tier |
| Hetzner | Fallback VPS, provisioned on demand via `make dr-full` | ~€7.85/mo, only if needed |
| GitHub | Repos, Actions, Renovate | Free |
| Let's Encrypt | HTTPS certificates | Free |
| healthchecks.io | Every scheduled job reports here | Free |
