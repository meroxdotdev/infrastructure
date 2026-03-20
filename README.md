# merox.dev Infrastructure

GitOps-managed homelab: Kubernetes cluster (Talos + Flux) + VPS services + Infrastructure agent.

> For a complete rebuild from scratch: **[DEPLOY.md](DEPLOY.md)**

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
│  ├── Cilium (CNI)                                       │
│  ├── Longhorn (storage → backs up to Garage S3)         │
│  ├── cert-manager, ingress-nginx, external-dns          │
│  └── Apps: see kubernetes/apps/                         │
└─────────────────────────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│  merox-agent — github.com/meroxdotdev/merox-agent       │
│  Telegram bot + CLI → Claude Code → kubectl/docker      │
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
| Synology DS223+ | NAS / Backup | 2x2TB HDD RAID1 |
| XCY X44 | pfSense Firewall | N100, 8GB |
| Oracle/Hetzner VPS | Off-site services | 4 vCPU, 8GB |

---

## Repository Layout

```
infrastructure/
├── cloudlab-infrastructure/    # Ansible — VPS provisioning
├── kubernetes/
│   ├── apps/                   # Flux app manifests (namespaced)
│   ├── flux/                   # Flux system config
│   └── components/             # Shared Helm release templates
├── talos/                      # Talos node configs + patches
├── bootstrap/                  # Cluster bootstrap vars + tasks
├── DEPLOY.md                   # Full rebuild guide (start here)
└── Taskfile.yaml               # Task runner (talosctl, flux, etc.)
```

---

## Common Operations

### Cluster

```bash
# Force Flux sync
task reconcile

# Apply Talos config to a node
task talos:apply-node IP=10.57.57.80

# Upgrade Talos (update talenv.yaml first)
task talos:upgrade-node IP=10.57.57.80
task talos:upgrade-k8s

# Reset cluster
task talos:reset
```

### VPS

```bash
cd cloudlab-infrastructure/

make setup          # Full redeploy (idempotent)
make update         # OS package updates only
make health-check   # Verify all services running
make check          # Dry-run (--check --diff)
make check-resources # Disk, memory, Docker usage
make cleanup        # Remove unused Docker images/volumes
```

### Quick status

```bash
kubectl get nodes
flux check
kubectl -n longhorn-system get nodes.longhorn.io
docker exec garage /garage status
```

---

## Troubleshooting

### Flux

```bash
flux get kustomizations -A
flux logs
```

### Pod issues

```bash
kubectl -n <namespace> logs <pod> -f
kubectl -n <namespace> describe pod <pod>
```

### Node issues

```bash
kubectl describe node <node-name>
talosctl -n <node-ip> dmesg
```

### Longhorn storage

```bash
kubectl -n longhorn-system get volumes
kubectl get orphan -n longhorn-system
# Delete orphans:
kubectl get orphan -n longhorn-system -o name | xargs kubectl delete -n longhorn-system
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

# 5. Fix Longhorn disk (if UUID changed):
kubectl -n longhorn-system patch node.longhorn.io <node> \
  --type merge -p '{"spec":{"evictionRequested":true}}'
# Wait for replicas to evacuate, then remove old disk and add new one
# See DEPLOY.md for full Longhorn disk replacement steps
```

**Wait 1-2 hours between disk swaps** to allow replica rebuild.

---

## Longhorn Cleanup

```bash
# Orphaned replicas
kubectl get orphan -n longhorn-system -o name | \
  xargs kubectl delete -n longhorn-system
kubectl delete pod -n longhorn-system -l app=longhorn-manager

# Old snapshots
kubectl get snapshots -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.creationTime < "2025-11-01") | .metadata.name' | \
  xargs kubectl delete snapshot -n longhorn-system
```

---

## Security

- Kubernetes secrets encrypted with SOPS (AGE keys)
- Ansible secrets in encrypted Vault
- Auto-updates via Renovate
- Report vulnerabilities: [SECURITY.md](SECURITY.md)
