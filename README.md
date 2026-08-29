# merox.dev Infrastructure

Single-node Talos Kubernetes cluster on Proxmox, plus an Oracle Cloud VPS for
off-site services. Everything is declarative and GitOps-managed: `git push`
deploys, updates or rebuilds any part.

Rebuild from nothing takes ~35 minutes and needs three things — this repo,
`age.key`, and the restic password.

**This page is the index.** Anything with real detail lives behind a link.

## The whole thing, in six lines

Read this first if it has been a while.

| | |
|---|---|
| **Network** | pfSense routes and hands out addresses. Tailscale is the only way in from outside and nothing is port-forwarded; what is public reaches the internet through an outbound-only Cloudflare tunnel. |
| **Compute** | One Proxmox host (`pve`) runs a single-node Talos Kubernetes cluster in VM 800. Flux reconciles it from this repo, so a push is the deploy — there is no other way to change it. |
| **Storage** | ZFS. `media` is twelve SAS disks in two raidz2 vdevs, holds bulk and spins down when idle; `rpool` is a mirrored SSD pair holding anything an application touches during the day. |
| **Backup** | Every source writes into `/media/backups/` on pve. From there restic pushes it to Oracle nightly, and a weekly rsync relays a plain-file copy to the Synology. Only what git cannot rebuild is backed up. |
| **Off-site** | An Oracle Cloud VPS runs what should outlive the house: Authentik SSO, Traefik, Pi-hole, Joplin, Guacamole, Homepage. It depends on nothing at home, pushes its own state to pve nightly, and is rebuilt with `cd vps && make dr-full`. Tailscale is what joins the two sites. |
| **Recovery** | [`docs/dr-quickstart.md`](docs/dr-quickstart.md) — eight `task` commands, drilled on separate hardware. `age.key` and the restic password cannot be recreated; everything else can. |

Every scheduled job reports to healthchecks.io, so silence is the alarm.
`nightly-checks.sh` on pve also compares the host against this repo and fails
if they have drifted apart.

## Everything at a glance

### VPS — Oracle Cloud (`vps/` → `make setup`)

| Service | URL | Purpose |
|---|---|---|
| Traefik | traefik.cloud.merox.dev | Reverse proxy + ACME certs |
| Pi-hole + Unbound | pihole.cloud.merox.dev/admin | DNS ad-blocking + DoH resolver |
| Authentik | sso.merox.dev | SSO / identity provider |
| Portainer EE | 100.72.22.38:9000 _(Tailscale)_ | Container management UI |
| Homepage | homepage.cloud.merox.dev _(Tailscale)_ · inside.merox.dev _(public, curated)_ | Dashboards |
| Joplin Server | joplin.cloud.merox.dev | Notes sync (PostgreSQL) |
| Guacamole | rmt.merox.dev | Remote desktop gateway (Authentik SSO) |

### Kubernetes — on-premise (`kubernetes/` → Flux GitOps)

| Service | Namespace | Purpose |
|---|---|---|
| Jellyfin | default | Media server, LAN/Tailscale only (Quadro P2200 transcoding) |
| Jellyfin-public | default | Curated 1080p library, internet-facing — [how](docs/jellyfin-public-exposure.md) |
| Jellyseerr · Radarr · Sonarr · Prowlarr · qBittorrent | default | Media requests, automation, indexing, download |
| Immich | default | Photo/video library (photos.k8s.merox.dev) |
| n8n | default | Workflow automation |
| Headlamp | default | Kubernetes dashboard |
| Authentik outpost · Portainer agent | default | SSO proxy · Portainer |
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
| Dell R730xd — `pve`, `10.57.57.250` | Proxmox host and backup hub: the K8s control-plane VM, the Garage S3 LXC, NFS for the SAS pool, and every backup leg. [Runbook](proxmox/r730xd/README.md) · [Reinstall](proxmox/r730xd/REINSTALL.md) | Xeon E5-2630 v4 (10C/20T), 251GB DDR4, Quadro P2200 |
| XCY X44 — `fw`, `10.57.57.1` | pfSense: gateway, DHCP, Tailscale subnet router. [Reinstall](pfsense/REINSTALL.md) | N100, 8GB |
| Oracle Cloud ARM VPS | Off-site services | 4 vCPU ARM, 24GB, 200GB |
| Synology DS223+ — `10.57.57.201` | Cold storage only, weekly versioned push from pve | 2x2TB RAID1 |
| Beelink GTi13 Ultra | DR drill target, otherwise off | i9-13900HK, 64GB DDR5, 2x1TB NVMe |
| Dell OptiPlex 3050 ×2 | Retained, powered off | i5-6500T, 32GB, 128GB NVMe |

## Where to go

| I want to | Page |
|---|---|
| Rebuild everything from scratch | [DEPLOY.md](DEPLOY.md) — VPS first, then Kubernetes |
| Recover the cluster | [DR.md](DR.md) · [quickstart](docs/dr-quickstart.md) — eight commands |
| Understand the backups | [proxmox/r730xd/README.md](proxmox/r730xd/README.md) — every leg, schedule, retention |
| Run day-to-day things | [docs/operations.md](docs/operations.md) |
| Fix something broken | [docs/troubleshooting.md](docs/troubleshooting.md) · [DR known issues](docs/dr-known-issues.md) |
| Know what the code is | `kubernetes/` Flux manifests · `talos/` node configs · `vps/` Ansible + Terraform · `proxmox/` and `pfsense/` host runbooks |

**Total loss (fire, theft) — rebuild in this order**, because each layer needs
the one before it: pfSense (no gateway, no internet, no restic — console
access only) → pve (needs the restic password to pull `/root` back from
Oracle) → Kubernetes. The VPS is independent of all three: `cd vps && make
dr-full`, any time.

## External dependencies

| Service | Purpose | Cost |
|---|---|---|
| Cloudflare | DNS, Tunnel, Pages | Free |
| Tailscale | Management VPN mesh | Free |
| Oracle Cloud | Primary VPS | Free tier |
| Hetzner | Fallback VPS, provisioned on demand via `make dr-full` | ~€7.85/mo, only if needed |
| GitHub | Repos, Actions, Renovate | Free |
| Let's Encrypt | HTTPS certificates | Free |
| healthchecks.io | Every scheduled job reports here | Free |
