# merox.dev Infrastructure

Three Proxmox hosts, one Talos Kubernetes node each. An Oracle VPS off-site.
Everything is in git — `git push` is the deploy.

Rebuild from nothing: ~35 min, needs this repo + `age.key` + the restic password.

**This page is the index.** Detail lives behind the links.

---

## Architecture

| | |
|---|---|
| **Network** | pfSense routes. Tailscale in, Cloudflare tunnel out. Zero open ports. |
| **Compute** | 3 standalone hosts, joined by PDM, never corosync. One k8s node each, so 3 etcd votes in 3 chassis. Flux reconciles from this repo. |
| **Storage** | ZFS on pve-2. `media` = 12 SAS in 2× raidz2, spins down idle. `rpool` = SSD mirror, everything touched daily. |
| **Backup** | All sources → `/media/backups/` on pve-2 → restic to Oracle nightly + Synology pulls weekly. |
| **Recovery** | [dr-quickstart.md](docs/dr-quickstart.md) — 8 commands, drilled on separate hardware. |

**Nothing here is reachable from the internet.** [Why, and what was](docs/jellyfin-public-exposure.md).

**pve-2 can add to both backup targets and delete from neither.** Oracle is
append-only; the NAS holds no credential pve-2 can use. Retention runs on each
target. [Every leg](proxmox/pve-2/README.md#downstream-legs).

**One thing is not in Flux, on purpose.** Nextcloud is VM 1000 under AIO, which
needs the Docker socket. Evaluated 2026-09-09, left alone. Costs a weekly
`vzdump` and a third secret. [Detail](proxmox/pve-2/nextcloud/README.md).

**Silence is the alarm.** Every job reports to healthchecks.io. `nightly-checks.sh`
on pve-2 also fails if the host has drifted from this repo.

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
| Homepage | homepage.cloud.merox.dev · inside.merox.dev |
| Portainer | portainer.cloud.merox.dev |
| restic rest-server | :8000, append-only |

**Kubernetes** — `kubernetes/` → Flux

| Service | Namespace |
|---|---|
| Jellyfin · Jellyseerr · Radarr · Sonarr · Prowlarr · qBittorrent | default |
| Immich | default |
| n8n — one workflow, the news digest | default |
| Headlamp · Authentik outpost | default |
| Prometheus · Grafana · Loki · Alloy · Alertmanager | observability |
| Longhorn | longhorn-system |
| Cilium | kube-system |
| cert-manager | cert-manager |
| Cloudflare Tunnel · k8s-gateway · netboot.xyz | network |

The blog is a separate repo, `meroxdotdev/merox` → Cloudflare Pages.

---

## Hardware

| Device | Host | Runs | Specs |
|---|---|---|---|
| Beelink GTi13 Ultra | `pve-1` · .254 | `kubernetes-1` (VM 810) | i9-13900HK, 64GB, 2×1TB NVMe. Iris Xe passed through — **the only GPU**, so transcoding lives here. [Runbook](proxmox/pve-1/README.md) |
| Dell R730xd | `pve-2` · .250 | `kubernetes-2` (VM 811), Nextcloud (VM 1000), Garage LXC | Xeon E5-2630 v4, 251GB, 12× SAS + SSD mirror. Storage, backup hub, NFS. [Runbook](proxmox/pve-2/README.md) · [Reinstall](proxmox/pve-2/REINSTALL.md) |
| Dell OptiPlex 3050 | `pve-3` · .253 | `kubernetes-3` (VM 812), PDM | i5-6500T, 32GB, Intel D3-S4510 passed raw — **best etcd disk here**. [Runbook](proxmox/pve-3/README.md) |
| XCY X44 | `fw` · .1 | pfSense | N100, 8GB. Gateway, DHCP, Tailscale subnet router. [Reinstall](pfsense/REINSTALL.md) |
| Synology DS223+ | `storage` · .201 | Cold copy | 2×2TB RAID1. **Pulls** from pve-2, never pushed to. Asleep most of the week. [Runbook](synology/README.md) |
| Oracle ARM | `vps01` | Off-site services | 4 vCPU, 24GB, 200GB. Free tier |
| Dell OptiPlex 3050 | — | Cold spare, off | i5-6500T, 32GB |

---

## Three secrets you cannot lose

| Secret | Where | Losing it means |
|---|---|---|
| `age.key` | repo root (gitignored) + password manager | No K8s secret decrypts |
| restic password | password manager | The Oracle backup is unreadable |
| Borg passphrase | password manager | The Nextcloud archive is unreadable |

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
| Understand the backups | [proxmox/pve-2/README.md](proxmox/pve-2/README.md) |
| Run day-to-day things | [docs/operations.md](docs/operations.md) |
| Fix something broken | [docs/troubleshooting.md](docs/troubleshooting.md) · [DR known issues](docs/dr-known-issues.md) |
| See what is still planned | [docs/plan-2026-09.md](docs/plan-2026-09.md) |

**After a fire, rebuild in this order** — each layer needs the one before it:

1. **pfSense** — no gateway means no internet and no restic. Console only.
2. **pve-2** — needs the restic password to pull `/root` back from Oracle.
3. **Kubernetes** — from git.

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
