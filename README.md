
> Blog post https://merox.dev/blog/homelab-tour/

# 🏠 Homelab Infrastructure

## 🖥️ Hardware Inventory

| Device | CPU | RAM | Storage | Role | Status |
|--------|-----|-----|---------|------|--------|
| **Dell PowerEdge R720** | 2x Intel Xeon E5-2697 v2<br>(24 cores / 48 threads) | 192GB DDR3 | 4x Intel D3-S4510 960GB SSD | Proxmox Backup Server | 🟢 Active |
| **Dell OptiPlex 3050 #1** | Intel i5-6500T<br>(4 cores / 4 threads) | 16GB DDR4 | 128GB NVMe + 512GB SSD | Kubernetes Node<br>(Proxmox VM) | 🟢 Active |
| **Dell OptiPlex 3050 #2** | Intel i5-6500T<br>(4 cores / 4 threads) | 16GB DDR4 | 128GB NVMe + 512GB SSD | Kubernetes Node<br>(Proxmox VM) | 🟢 Active |
| **Beelink GTi 13 Pro** | Intel i9-13900H<br>(14 cores / 20 threads) | 64GB DDR5 | 2x 2TB NVMe | Kubernetes Node<br>(Proxmox VM) | 🟢 Active |
| **Synology DS223+** | ARM Realtek RTD1619B | 2GB DDR4 | 2x 2TB HDD<br>(RAID 1) | NAS / Media Server<br>Backup Target | 🟢 Active |
| **XCY X44** | Intel N100<br>(4 cores / 4 threads) | 8GB DDR4 | 128GB SSD | pfSense Firewall | 🟢 Active |
| **Hetzner CX32** | 4 vCPU | 8GB | 80GB SSD | Remote VPS<br>Off-site Backup | ☁️ Cloud |

## 🔌 Infrastructure Components

### 🔋 Power Protection
| Device | Model | Protected Equipment | Capacity |
|--------|-------|-------------------|----------|
| **UPS #1** | CyberPower | Dell R720 | 1500VA |
| **UPS #2** | CyberPower | Mini PCs + Network | 1000VA |

### 🌐 Network Equipment
| Device | Model | Ports | Role |
|--------|-------|-------|------|
| **Switch** | TP-Link | 24x 1Gb | Core Network Switch |

---

A streamlined Kubernetes cluster deployment using [Talos Linux](https://github.com/siderolabs/talos) and [Flux](https://github.com/fluxcd/flux2). Based on [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template).

## 📋 Prerequisites

- Knowledge of: Containers, YAML, Git
- **Cloudflare account** with a **domain**
- **Hardware**: 4 cores, 16GB RAM, 256GB SSD per node (3+ nodes recommended)

## 🛠️ Stack

- **OS**: Talos Linux
- **GitOps**: Flux (GitHub provider)
- **Secrets**: SOPS
- **Networking**: Cilium, Cloudflared
- **Core Apps**: cert-manager, spegel, reloader, external-dns
- **Automation**: Renovate, GitHub Actions
- **Dev Tools**: Mise

## 🚀 Quick Start

### 1️⃣ Prepare Nodes

1. Create Talos image at [factory.talos.dev](https://factory.talos.dev) (note the **schematic ID**)
2. Flash ISO/RAW to USB and boot nodes
3. Verify nodes: `nmap -Pn -n -p 50000 192.168.1.0/24 -vv | grep 'Discovered'`

### 2️⃣ Setup Workstation

```bash
# Create repo from template
export REPONAME="home-ops"
gh repo create $REPONAME --template onedr0p/cluster-template --public --clone && cd $REPONAME

# Install tools
mise trust && pip install pipx && mise install

# Logout registries
docker logout ghcr.io && helm registry logout ghcr.io
```

### 3️⃣ Configure Cloudflare

1. Create API token with permissions:
   - `Zone - DNS - Edit`
   - `Account - Cloudflare Tunnel - Read`
2. Create tunnel:
   ```bash
   cloudflared tunnel login
   cloudflared tunnel create --credentials-file cloudflare-tunnel.json kubernetes
   ```

### 4️⃣ Configure Cluster

```bash
task init                    # Generate config files
# Edit cluster.yaml and nodes.yaml
task configure              # Template configurations
git add -A && git commit -m "chore: initial commit" && git push
```

### 5️⃣ Bootstrap

```bash
task bootstrap:talos        # Install Talos (10+ min)
git add -A && git commit -m "chore: add secrets" && git push
task bootstrap:apps         # Deploy Cilium, Flux, etc.
kubectl get pods --all-namespaces --watch
```

## ✅ Post-Install Verification

```bash
cilium status                                    # Check Cilium
flux check                                       # Check Flux
flux get sources git flux-system                # Git sync status
nmap -Pn -n -p 443 ${gateway_addrs} -vv        # Gateway connectivity
dig @${dns_gateway} echo.${domain}              # DNS resolution
kubectl -n kube-system describe certificates     # SSL certs
```

## 🔧 Maintenance

### Update Talos Config
```bash
task talos:generate-config
task talos:apply-node IP=10.10.10.10 MODE=auto
```

### Upgrade Versions
```bash
# Update talenv.yaml first
task talos:upgrade-node IP=10.10.10.10    # Talos upgrade
task talos:upgrade-k8s                     # Kubernetes upgrade
```

### Reset Cluster
```bash
task talos:reset
```

## 🌐 DNS Setup

- **External**: Use `external` gateway in HTTPRoutes for public access
- **Internal**: Configure home DNS to forward `${domain}` → `${cluster_dns_gateway}`

## 🪝 GitHub Webhook

1. Get webhook path: `kubectl -n flux-system get receiver github-webhook --output=jsonpath='{.status.webhookPath}'`
2. Add to GitHub: `https://flux-webhook.${domain}${webhook_path}`

## 🐛 Troubleshooting

```bash
task reconcile                                   # Force Flux sync
flux get sources git -A                          # Check sources
kubectl -n <namespace> logs <pod> -f            # Pod logs
kubectl -n <namespace> describe <resource>       # Resource details
kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
```

## 🧹 Cleanup

```bash
task template:tidy          # Remove template files
git add -A && git commit -m "chore: cleanup" && git push
```

## 💡 Next Steps

- **Alternative DNS**: Consider [external-dns](https://github.com/kubernetes-sigs/external-dns) providers
- **Secret Management**: Explore [External Secrets](https://external-secrets.io)
- **Storage Options**: rook-ceph, longhorn, openebs, democratic-csi

## 🔒 Security & Quality

This repository follows security best practices:

- **Secrets**: All secrets encrypted with SOPS (AGE keys)
- **Security Scanning**: Automated Trivy and Gitleaks scans via GitHub Actions
- **Dependency Updates**: Renovate + Dependabot for automated updates
- **Security Policy**: See [SECURITY.md](SECURITY.md) for vulnerability reporting

## 📚 Documentation

- [Repository Analysis](REPOSITORY_ANALYSIS.md) - Comprehensive repository review
- [Contributing Guidelines](CONTRIBUTING.md) - How to contribute
- [Security Policy](SECURITY.md) - Security reporting and practices
- [Changelog](CHANGELOG.md) - Version history and changes
- [Apps Directory](kubernetes/apps/README.md) - Application organization guide

## 🙋 Support

- [GitHub Discussions](https://github.com/onedr0p/cluster-template/discussions)
- [Home Operations Discord](https://discord.gg/home-operations) (#support, #cluster-template)

---

*For detailed documentation, refer to the [original template](https://github.com/onedr0p/cluster-template)*
