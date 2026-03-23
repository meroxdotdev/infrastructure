# merox.dev Infrastructure

GitOps-managed homelab: Kubernetes cluster (Talos + Flux) + VPS services + Infrastructure agent.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  VPS (Oracle/Hetzner)   cloudlab-infrastructure/        │
│  ├── Traefik (reverse proxy + SSL)                      │
│  ├── Pi-hole (DNS)                                      │
│  ├── Portainer (container management)                   │
│  ├── Homepage (dashboard)                               │
│  ├── Netdata (monitoring)                               │
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

| Device | Role | Specs |
|--------|------|-------|
| Dell OptiPlex 3050 #1 | K8s node (Proxmox VM) | i5-6500T, 16GB, 128GB NVMe |
| Dell OptiPlex 3050 #2 | K8s node (Proxmox VM) | i5-6500T, 16GB, 128GB NVMe |
| Beelink GTi 13 Pro | K8s node (Proxmox VM) | i9-13900H, 64GB, 2x2TB NVMe |
| Dell PowerEdge R720 | Proxmox Backup Server | 2x Xeon E5-2697v2, 192GB |
| Synology DS223+ | NAS / NFS + Backup | 2x2TB HDD RAID1 |
| XCY X44 | pfSense Firewall | N100, 8GB |
| Oracle/Hetzner VPS | Off-site services | 4 vCPU, 8GB |

---

## Repository Layout

```
infrastructure/
├── cloudlab-infrastructure/    # Ansible — VPS provisioning
├── kubernetes/
│   ├── apps/                   # Flux app manifests (namespaced)
│   ├── flux/                   # Flux bootstrap + HelmRepositories
│   └── components/             # Shared Kustomize components (common, repos)
├── talos/                      # Talos node configs + patches
├── bootstrap/                  # Cluster bootstrap vars
├── agent/                      # OpenClaw config template + infra skill
│   ├── openclaw.json           # Gateway config (no secrets — use ~/.openclaw/.env)
│   └── skills/infra/           # kubectl/docker skill context
├── DEPLOY.md                   # Full rebuild + DR guide
└── Taskfile.yaml               # Task runner (talosctl, flux, etc.)
```

---

## Disaster Recovery

> Full step-by-step rebuild guide: **[DEPLOY.md](DEPLOY.md)**

| Scenario | Where to look |
|----------|--------------|
| Full rebuild (new server + new cluster) | [DEPLOY.md — Phase 1 (VPS)](DEPLOY.md#phase-1--vps) → [Phase 2 (K8s)](DEPLOY.md#phase-2--kubernetes-cluster) → [Phase 3 (Agent)](DEPLOY.md#phase-3--agent-openclaw) |
| Restore Longhorn volumes from S3 backup | [DEPLOY.md — Phase 2, step 6](DEPLOY.md#phase-2--kubernetes-cluster): `task restore:longhorn` |
| New hardware (different IPs/disks) | [DEPLOY.md — Phase 2, step 3](DEPLOY.md#phase-2--kubernetes-cluster): update `talos/talconfig.yaml`, `cluster-vars.yaml`, `cilium/networks.yaml` |
| Intel iGPU absent on new hardware | Remove `gpu.intel.com/i915` from `kubernetes/apps/default/jellyfin/app/helmrelease.yaml` and disable `intel-device-plugin-operator` |
| Re-install OpenClaw agent only | [DEPLOY.md — Phase 3](DEPLOY.md#phase-3--agent-openclaw) |

**The two things to back up before decommissioning a server:**
1. `age.key` — losing this = losing all SOPS-encrypted secrets
2. `~/.openclaw/.env` — Anthropic API key, Telegram tokens

---

## Day-to-Day Operations

### Cluster

```bash
# Check overall health
kubectl get nodes
kubectl get kustomizations -A
kubectl get helmreleases -A

# Force Flux sync
task reconcile

# Apply Talos config to a node
task talos:apply-node IP=10.57.57.80

# Upgrade Talos on a node (update talenv.yaml version first)
task talos:upgrade-node IP=10.57.57.80
task talos:upgrade-k8s

# Reset entire cluster (destructive)
task talos:reset
```

### VPS

```bash
cd cloudlab-infrastructure/

make health-check     # Verify all services running
make setup            # Full redeploy (idempotent)
make update           # OS package updates only
make check            # Dry-run (--check --diff)
make check-resources  # Disk, memory, Docker usage
make cleanup          # Remove unused Docker images/volumes
```

---

## Troubleshooting

### Flux not reconciling

```bash
flux get kustomizations -A          # Find which ks is failing
flux logs --level=error             # See error messages
flux reconcile kustomization cluster-apps --with-source  # Force sync
```

### HelmRelease stuck / failed

```bash
kubectl get helmreleases -A | grep -v True
flux logs --kind HelmRelease --name <name> -n <namespace>
flux reconcile helmrelease <name> -n <namespace> --with-source
# If values changed and Helm refuses: suspend + resume
flux suspend helmrelease <name> -n <namespace>
flux resume helmrelease <name> -n <namespace>
```

### Pod issues

```bash
kubectl -n <namespace> get pods
kubectl -n <namespace> describe pod <pod>
kubectl -n <namespace> logs <pod> -f
kubectl -n <namespace> logs <pod> --previous   # crashed container
```

### Longhorn storage

```bash
# Volume / replica status
kubectl -n longhorn-system get volumes
kubectl -n longhorn-system get nodes.longhorn.io

# Orphaned replicas (safe to delete)
kubectl get orphan -n longhorn-system -o name | \
  xargs kubectl delete -n longhorn-system

# Trigger a backup manually
# Longhorn UI → Volume → Create Backup

# Old snapshots cleanup
kubectl get snapshots -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.creationTime < "2025-01-01") | .metadata.name' | \
  xargs kubectl delete snapshot -n longhorn-system
```

### Replacing a disk on a K8s node

```bash
# 1. Drain node
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# 2. In Proxmox: shutdown VM, swap physical disk, boot VM

# 3. Re-provision Talos
talosctl apply-config --insecure --nodes <ip> \
  --file talos/clusterconfig/<node>.yaml

# 4. Uncordon
kubectl uncordon <node>

# 5. If Longhorn disk UUID changed — evict replicas then re-add disk:
kubectl -n longhorn-system patch node.longhorn.io <node> \
  --type merge -p '{"spec":{"evictionRequested":true}}'
# Wait for replicas to evacuate (~20-60 min), then remove old disk
# and add new disk via Longhorn UI
```

> Wait 1-2 hours between disk swaps to allow replica rebuild.

### Node unreachable

```bash
talosctl -n <node-ip> health
talosctl -n <node-ip> dmesg
talosctl -n <node-ip> services
kubectl describe node <node-name>
```

### Garage S3 (Longhorn backup target)

```bash
ssh root@<vps-ip> "docker exec garage /garage status"
ssh root@<vps-ip> "docker exec garage /garage bucket list"
# Verify Longhorn can reach it:
kubectl -n longhorn-system get secret minio-secret
```

---

## Maintenance

### Dependency updates

Renovate runs every weekend and opens PRs automatically for:
- Helm chart versions (all HelmReleases)
- Container image tags (annotated with `# renovate:`)
- Talos / Kubernetes versions (`.mise.toml`)

Config: `.renovaterc.json5`

### SOPS secret rotation

```bash
# Edit any encrypted secret
sops kubernetes/apps/<namespace>/<app>/app/secret.sops.yaml

# Re-encrypt all secrets after AGE key rotation
find . -name "*.sops.*" -exec sops updatekeys {} \;
```

### Security

- Kubernetes secrets encrypted with SOPS (AGE key — back up manually)
- Ansible secrets in encrypted Vault (`cloudlab-infrastructure/`)
- All traffic via Tailscale mesh or Cloudflare Tunnel (no open ports)
