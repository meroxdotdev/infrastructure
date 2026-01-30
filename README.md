# 🏠 Homelab Infrastructure

> Blog post: https://merox.dev/blog/homelab-tour/

GitOps-managed Kubernetes cluster using Talos Linux + Flux. Based on [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template).

## 🖥️ Hardware

| Device | CPU | RAM | Storage | Role |
|--------|-----|-----|---------|------|
| Dell PowerEdge R720 | 2x Xeon E5-2697 v2 (48T) | 192GB | 4x Intel D3-S4510 960GB | Proxmox Backup Server |
| Dell OptiPlex 3050 #1 | i5-6500T (4T) | 16GB | 128GB NVMe + Intel D3-S4510 | K8s Node (Proxmox VM) |
| Dell OptiPlex 3050 #2 | i5-6500T (4T) | 16GB | 128GB NVMe + Intel D3-S4510 | K8s Node (Proxmox VM) |
| Beelink GTi 13 Pro | i9-13900H (20T) | 64GB | 2x 2TB NVMe | K8s Node (Proxmox VM) |
| Synology DS223+ | Realtek RTD1619B | 2GB | 2x 2TB HDD (RAID1) | NAS / Backup |
| XCY X44 | Intel N100 | 8GB | 128GB SSD | pfSense Firewall |
| Hetzner CX32 | 4 vCPU | 8GB | 80GB SSD | Off-site Backup (Cloud) |

**Power**: 2x CyberPower UPS (1500VA + 1000VA)  
**Network**: TP-Link 24-port Gigabit Switch

---

## 🚀 Quick Start

### Prerequisites
- Cloudflare account + domain
- 3+ nodes: 4 cores, 16GB RAM, 256GB storage each

### 1. Bootstrap Talos Cluster

```bash
# Clone repo
git clone <your-repo> && cd infrastructure

# Install tools
mise trust && mise install

# Generate configs
task init
# Edit: bootstrap/vars/cluster.yaml, talos/nodes.yaml

# Template configs
task configure
git add -A && git commit -m "initial setup" && git push

# Install Talos (10-15 min)
task bootstrap:talos
git add -A && git commit -m "add secrets" && git push

# Deploy apps
task bootstrap:apps
kubectl get pods -A --watch
```

### 2. Verify Deployment

```bash
kubectl get nodes                    # All nodes Ready
flux check                          # Flux healthy
cilium status                       # Cilium running
kubectl -n longhorn-system get nodes.longhorn.io  # Storage ready
```

---

## 🔧 Common Operations

### Force Flux Sync
```bash
task reconcile
```

### Apply Talos Config to Node
```bash
task talos:apply-node IP=10.57.57.80
```

### Upgrade Talos/K8s
```bash
# Update talenv.yaml first
task talos:upgrade-node IP=10.57.57.80
task talos:upgrade-k8s
```

### Reset Cluster
```bash
task talos:reset
```

---

## 💾 Hardware Maintenance

### Replacing Disk on Proxmox Node

**Example**: Swapping failed SSD on OptiPlex K8s node

```bash
# 1. Drain K8s node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 2. Verify pods migrated
kubectl get pods -A -o wide | grep <node-name>

# 3. In Proxmox: shutdown VM, swap physical disk, boot VM
# VM will boot to maintenance mode (no config)

# 4. Re-provision Talos with fresh config (INSECURE mode for first boot)
talosctl apply-config --insecure \
  --nodes <node-ip> \
  --file talos/clusterconfig/<node-config-file>.yaml

# Wait for node to join cluster (~2-5 min)
kubectl get nodes -w

# 5. Uncordon node
kubectl uncordon <node-name>

# 6. Fix Longhorn storage (if disk UUID changed):
kubectl -n longhorn-system patch node.longhorn.io <node-name> \
  --type merge -p '{"spec":{"allowScheduling":false}}'

kubectl -n longhorn-system patch node.longhorn.io <node-name> \
  --type merge -p '{"spec":{"evictionRequested":true}}'

# Wait for replicas to evacuate (~1-2 min)
kubectl -n longhorn-system get replicas -o wide | grep <node-name>

# Disable old disk
kubectl -n longhorn-system patch node.longhorn.io <node-name> \
  --type merge \
  -p='{"spec":{"disks":{"default-disk-OLDID":{"allowScheduling":false}}}}'

# Remove old disk (get ID from: kubectl -n longhorn-system get node.longhorn.io <node-name> -o yaml)
kubectl -n longhorn-system patch node.longhorn.io <node-name> \
  --type json -p='[{"op":"remove","path":"/spec/disks/default-disk-OLDID"}]'

# Cancel eviction and re-enable
kubectl -n longhorn-system patch node.longhorn.io <node-name> \
  --type merge -p '{"spec":{"evictionRequested":false,"allowScheduling":true}}'

# Add new disk
kubectl -n longhorn-system patch node.longhorn.io <node-name> \
  --type merge \
  -p='{"spec":{"disks":{"default-disk":{"allowScheduling":true,"path":"/var/lib/longhorn/","storageReserved":0,"tags":[]}}}}'

# 7. Verify storage ready (wait ~30 sec)
kubectl -n longhorn-system get node.longhorn.io <node-name>
# Should show: READY=True, ALLOWSCHEDULING=true, SCHEDULABLE=True

# 8. Monitor replica rebuild
kubectl -n longhorn-system get replicas | grep <node-name>
```

**Wait 1-2 hours between disk swaps** to allow Longhorn replica rebuild.

---

## 🐛 Troubleshooting

```bash
# Flux issues
flux get kustomizations -A
flux logs

# Pod issues
kubectl -n <namespace> logs <pod> -f
kubectl -n <namespace> describe pod <pod>

# Node issues
kubectl describe node <node-name>
talosctl -n <node-ip> dmesg

# Longhorn issues
kubectl -n longhorn-system get volumes
kubectl -n longhorn-system describe node.longhorn.io <node-name>
```

### Longhorn Storage Cleanup

**Clean orphaned replicas** (stale data from deleted volumes):
```bash
# Check for orphaned replicas
kubectl get orphan -n longhorn-system

# Count orphans per node
kubectl get orphan -n longhorn-system -o json | \
  jq -r '.items[] | .spec.nodeID' | sort | uniq -c

# Delete all orphaned replicas
kubectl get orphan -n longhorn-system -o name | \
  xargs kubectl delete -n longhorn-system

# Restart Longhorn managers to trigger cleanup
kubectl delete pod -n longhorn-system -l app=longhorn-manager

# Wait for cleanup (2-5 min), then verify space freed
kubectl get nodes -o wide
```

**Clean old snapshots** (backups older than 30 days):
```bash
# List snapshots
kubectl get snapshots -n longhorn-system

# Delete snapshots by pattern (testback, snap-, etc.)
kubectl get snapshots -n longhorn-system | \
  grep -E "testback-|snap-" | \
  awk '{print $1}' | \
  xargs kubectl delete snapshot -n longhorn-system

# Or delete snapshots older than specific date
kubectl get snapshots -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.creationTime < "2025-11-01") | .metadata.name' | \
  xargs kubectl delete snapshot -n longhorn-system
```

**Check disk usage** (Talos nodes):
```bash
# View replica directories on node
talosctl -n <node-ip> ls /var/lib/longhorn/replicas/

# Check Longhorn storage status
kubectl get nodes.longhorn.io -n longhorn-system
```
---

## 📚 Documentation

- [Repository Analysis](REPOSITORY_ANALYSIS.md)
- [Security Policy](SECURITY.md)
- [Changelog](CHANGELOG.md)

## 🔒 Security

- Secrets encrypted with SOPS (AGE keys)
- Auto-updates via Renovate + Dependabot
- Report vulnerabilities: See [SECURITY.md](SECURITY.md)

---

**Support**: [GitHub Discussions](https://github.com/onedr0p/cluster-template/discussions) | [Home Operations Discord](https://discord.gg/home-operations)
