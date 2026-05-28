# USER.md — Merox

- **Name:** Merox (Robert)
- **Timezone:** Europe/Bucharest
- **Communication language:** Romanian (for all Telegram messages)

## Managed infrastructure

### Kubernetes (Talos + FluxCD)
- Nodes: Dell OptiPlex 3050 ×2, Beelink GTi 13 Pro — all on Proxmox
- K8s config repo: `meroxdotdev/infrastructure` at `/srv/kubernetes/infrastructure/`
- Kubeconfig: `/home/openclaw/.kube/config`
- Talosconfig: `/home/openclaw/.talos/config`

### Oracle Cloud VPS
- OS: Ubuntu, 4 vCPU ARM, 24GB RAM
- Domain: merox.dev, *.cloud.merox.dev
- Reverse proxy: Traefik v3 with Cloudflare DNS

### Homelab hardware
- Dell PowerEdge R720: Proxmox Backup Server
- Synology DS223+: NAS, NFS + backup
- XCY X44: pfSense firewall
- Tailscale: mesh VPN

## Preferences

- Direct, actionable alerts — no spam
- Confirm before any destructive operation
- Never touch secrets (age.key, *.sops.yaml, .env)
