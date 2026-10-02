# merox.dev Infrastructure

Three Proxmox hosts, one Talos Kubernetes node each. An Oracle VPS off-site.
Everything is in git — `git push` is the deploy.

Rebuild from nothing: ~35 min, needs this repo + `age.key` + the restic password.
The data itself lives on the NAS, with an offline copy on the vault and an
off-site copy on Oracle.

**This page is the index.** Detail lives behind the links.

---

## Architecture

| | |
|---|---|
| **Network** | pfSense routes. Tailscale in, Cloudflare tunnel out. Zero open ports. |
| **Compute** | 3 standalone hosts, joined by PDM, never corosync. One k8s node each, so 3 etcd votes in 3 chassis. Flux reconciles from this repo. |
| **Storage** | The Synology NAS is the one live store: media (NFS to the cluster), Synology Drive, Synology Photos, and every backup's landing spot. Longhorn keeps app volumes on the nodes, three replicas. |
| **Backup** | Every producer writes to the NAS. The **vault** (R730xd, TrueNAS) wakes daily at an undisclosed hour, pulls the NAS read-only, snapshots, pushes restic to Oracle and powers itself off. [truenas/README.md](truenas/README.md) |
| **Recovery** | [dr-quickstart.md](docs/dr-quickstart.md) — 8 commands, drilled on separate hardware. |

**Nothing here is reachable from the internet.** Public names go through the Cloudflare tunnel to the VPS; the homelab is reached over Tailscale only.

**Nothing can reach the copies that could destroy them.** The vault pulls
from the NAS and nothing holds a credential into the vault; it is powered off
~22 hours a day. Oracle is append-only, and its retention runs on the VPS, the
only host with delete rights.

**Silence is the alarm.** Every scheduled job reports to healthchecks.io, and
TrueNAS sends disk and pool alerts to Telegram.

---

## Services

**VPS** — `vps/` → `make setup`

| Service | Where |
|---|---|
| Authentik | sso.merox.dev |
| Traefik | traefik.cloud.merox.dev |
| Pi-hole + Unbound | pihole.cloud.merox.dev/admin |
| Joplin | joplin.cloud.merox.dev |
| Guacamole | rmt.merox.dev |
| Homepage | inside.merox.dev — public contents page for the [homelab tour](https://merox.dev/blog/homelab-tour) |
| Portainer | portainer.cloud.merox.dev |
| restic rest-server | :8000, append-only |
| Syncthing | encrypted member of the [Sync folder](docs/sync.md) |

**Kubernetes** — `kubernetes/` → Flux

| Service | Namespace |
|---|---|
| Jellyfin · Jellyseerr · Radarr · Sonarr · Prowlarr · qBittorrent | default |
| n8n — one workflow, the news digest | default |
| Syncthing — the 24/7 [Sync folder](docs/sync.md) | default |
| Headlamp · Authentik outpost | default |
| Homepage — `home.k8s.merox.dev`, the internal dashboard | default |
| Prometheus · Grafana · Loki · Alloy · Alertmanager | observability |
| Longhorn | longhorn-system |
| Cilium | kube-system |
| cert-manager | cert-manager |
| Cloudflare Tunnel · k8s-gateway · netboot.xyz | network |

The blog is a separate repo, `meroxdotdev/merox` → Cloudflare Pages.

---

## Hardware

| Device | Host | Runs |
|---|---|---|
| Beelink GTi13 Ultra | `pve-1` · .254 | `kubernetes-1` — **the only GPU**, transcoding lives here |
| Dell OptiPlex 3050 | `pve-2` · .252 | `kubernetes-2` |
| Dell OptiPlex 3050 | `pve-3` · .253 | `kubernetes-3`, PDM, Garage (Longhorn's backup target, data on the NAS) |
| Dell R730xd | `vault` · .250 | TrueNAS, the offline copy. Off except for its daily run |
| XCY X44 | `fw` · .1 | pfSense — gateway, DHCP, Tailscale subnet router |
| Synology DS223 | `nas` · .201 | The live store: media, Drive, Photos, backup landing |
| Oracle ARM | `vps01` | Off-site services and the off-site restic repository |

Runbooks: [pve-1](proxmox/pve-1/README.md) · [pve-2](proxmox/pve-2/README.md) ·
[pve-3](proxmox/pve-3/README.md) · [vault](truenas/README.md) ·
[pfSense](pfsense/REINSTALL.md) · [Synology](synology/README.md). Specs and the reasoning behind each box are on
the [homelab tour](https://merox.dev/blog/homelab-tour/).

---

## Three secrets you cannot lose

| Secret | Where | Losing it means |
|---|---|---|
| `age.key` | repo root (gitignored) + password manager | No K8s secret decrypts |
| restic password | password manager | The Oracle backup is unreadable |
| vault pool key | password manager | The vault's disks are unreadable after a TrueNAS reinstall |

None can be recovered from a backup — each protects the thing that would hold
its copy. Keep a second copy somewhere that is not a password manager.

Everything else is reproducible: SOPS/age for K8s, Ansible Vault for the VPS,
`talos/talsecret.sops.yaml` for the cluster. Keep `vps/.vault_pass` and
`/srv/docker/oracle-cloud/.env` copied off the VPS.

---

## Where to go

| I want to | Page |
|---|---|
| Rebuild everything | [DEPLOY.md](DEPLOY.md) |
| Recover the cluster | [DR.md](DR.md) · [quickstart](docs/dr-quickstart.md) |
| Understand the backups | [docs/architecture.md](docs/architecture.md) · [truenas/README.md](truenas/README.md) |
| Run day-to-day things | [docs/operations.md](docs/operations.md) |
| Fix something broken | [docs/troubleshooting.md](docs/troubleshooting.md) · [DR known issues](docs/dr-known-issues.md) |
| Rebuild the vault | [truenas/RUNBOOK.md](truenas/RUNBOOK.md) |

**After a fire, rebuild in this order** — each layer needs the one before it:

1. **pfSense** — no gateway means no internet and no restic. Console only.
2. **NAS** — restored from the vault, or from Oracle if the vault is gone too.
   Garage's store and every backup landing spot live on it.
3. **Kubernetes** — from git; volumes come back from Longhorn's backups.

The VPS is independent of all three: `cd vps && make dr-full`, any time.

---

## External dependencies

| Service | For | Cost |
|---|---|---|
| Cloudflare | DNS, tunnel, Pages | Free |
| Tailscale | The only way in | Free |
| Oracle Cloud | Off-site VPS | Free tier |
| GitHub | Repo, Actions, Renovate | Free |
| Let's Encrypt | Certificates | Free |
| healthchecks.io | Every scheduled job | Free |
| Hetzner | Fallback VPS, on demand | ~€7.85/mo if used |
