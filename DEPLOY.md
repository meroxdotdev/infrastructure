# Infrastructure Deploy Guide

Complete rebuild procedure for a new server: VPS → Kubernetes cluster → Agent.

---

## Prerequisites

Before starting, have these ready:

| Item | Where to find it |
|------|-----------------|
| Vault password | Password manager |
| AGE key (`age.key`) | Backed up separately — **critical** |
| Tailscale reusable auth key | Tailscale admin console |
| Cloudflare API token | Cloudflare dashboard |
| Portainer EE license | Portainer account |
| Telegram bot token + user ID | BotFather / Telegram |
| Anthropic API key | console.anthropic.com |
| OpenClaw `.env` (`~/.openclaw/.env`) | Backed up separately |

---

## Phase 1 — VPS

> ~10 min. Sets up Docker, Tailscale, Traefik, Pi-hole, Portainer, Homepage, Netdata, Garage S3.

**On the new server**, create a root SSH key if not already present, then from your machine:

```bash
cd cloudlab-infrastructure/

# 1. Update inventory with new server IP
nano inventories/production/hosts
# Change: ansible_host=<NEW_IP>

# 2. Update Cloudflare DNS A records for *.cloud.merox.dev → <NEW_IP>
#    (Do this first so Let's Encrypt ACME can complete during deploy)

# 3. Install Ansible collections
make install

# 4. Test connectivity
make ping

# 5. Full deploy (~10 min)
make setup
# Enter vault password when prompted
```

**Post-deploy manual steps:**

```bash
# Portainer: set admin password at https://portainer.cloud.merox.dev
# Pi-hole: verify DNS at https://pihole.cloud.merox.dev/admin

# Retrieve Garage S3 credentials and save to vault:
ssh root@<NEW_IP> "docker exec garage /garage key info longhorn-key --show-secret"
ansible-vault edit inventories/production/group_vars/all/vault.yml
# Add: garage_access_key_id and garage_secret_access_key
```

**Verify:**
```bash
make health-check
```

---

## Phase 2 — Kubernetes Cluster

> ~20 min. Talos Linux + FluxCD + all apps via GitOps.

```bash
cd /srv/kubernetes/infrastructure/

# 1. Install tools (mise manages talosctl, kubectl, flux, task, etc.)
mise trust && mise install

# 2. Place AGE key
cp /path/to/age.key ./age.key

# 3. Adapt config for new hardware — edit these 3 files:

# --- a) Node IPs, VIP, install disk ---
# Edit: talos/talconfig.yaml
#   nodes[*].ipAddress          → new node IPs
#   endpoint                    → new VIP (e.g. https://10.x.x.88:6443)
#   nodes[*].installDisk        → /dev/sda (SATA/SAS) or /dev/nvme0n1 (NVMe)
#   controlPlane.ingressAddress → new VIP
#
# NOTE: if you add/remove Talos extensions (GPU, iSCSI, etc.) generate a new
# image ID at https://factory.talos.dev and update talosImageURL
#
# To get disk and MAC info from a node booted in maintenance mode:
#   talosctl get disks -n <ip> --insecure
#   talosctl get links -n <ip> --insecure

# --- b) All infrastructure IPs used by apps (Flux postBuild substitution) ---
# Edit: kubernetes/components/common/cluster-vars.yaml
#   NFS_SERVER              → NAS/NFS server IP
#   HOMEPAGE_PROXMOX_IP     → Proxmox host IP
#   HOMEPAGE_ROUTER_IP      → Router/gateway IP
#   HOMEPAGE_MYSPEED_IP     → MySpeed service IP
#   LB_IP_GATEWAY_INTERNAL  → Cilium internal gateway LB IP
#   LB_IP_QBITTORRENT       → qBittorrent LB IP
#   LB_IP_PORTAINER         → Portainer agent LB IP
#   LB_IP_K8S_GATEWAY       → k8s-gateway (DNS) LB IP
#   LB_IP_GATEWAY_EXTERNAL  → Cilium external gateway LB IP
#
# These values are injected into every namespace via the 'common' Kustomize
# component. This is the single place to change all infrastructure IPs.

# --- c) Cilium LB pool subnet ---
# Edit: kubernetes/apps/kube-system/cilium/app/networks.yaml
#   blocks[0].cidr           → new subnet (e.g. "10.x.x.0/24")
#   Must contain all LB_IP_* values above.

# 4. Verify nodes are booted into Talos maintenance mode and reachable
#    (replace with your subnet)
nmap -Pn -n -p 50000 10.57.57.0/24 -vv | grep 'Discovered'

# 5. Bootstrap Talos on all nodes (~10 min)
task bootstrap:talos
git add -A && git commit -m "chore: add secrets" && git push

# 6. Bootstrap Flux and wait for Longhorn to be ready (do NOT let Flux reconcile apps yet)
task bootstrap:apps
# Wait until Longhorn is fully running before proceeding:
kubectl -n longhorn-system wait helmrelease/longhorn --for=condition=Ready --timeout=5m
kubectl -n longhorn-system get nodes.longhorn.io   # All nodes should appear

# 7. Restore all Longhorn volumes from S3 backup (CRITICAL — run BEFORE apps start)
#    This restores: jellyfin, jellyseerr, prowlarr, qbittorrent, radarr, sonarr,
#                   loki, prometheus, n8n, grafana
task restore:longhorn
# Wait for all volumes to finish restoring (~5-10 min):
kubectl get volumes.longhorn.io -n longhorn-system --watch

# 8. Flux reconciles all apps — PVCs will auto-bind to restored PVs
kubectl get pods -A --watch
```

**Verify:**
```bash
# Nodes and Flux
kubectl get nodes                                    # All Ready
kubectl get kustomizations -A                        # All True
flux get sources git flux-system                     # READY True

# Storage
kubectl get pvc -A | grep -v Bound                   # Should be empty (all Bound)
kubectl -n longhorn-system get nodes.longhorn.io     # All nodes present

# Networking
cilium status                                        # All OK
nmap -Pn -n -p 443 10.57.57.101 10.57.57.112 -vv   # Both gateways reachable
dig @10.57.57.111 echo.merox.dev                    # Should resolve to 10.57.57.112
kubectl -n network describe certificates            # Certificate Ready
```

**Reconnect Longhorn → Garage S3 backup target:**

```bash
# Verify backupTarget points to: s3://longhorn@us-east-1/
# and minio-secret has the new credentials from Phase 1
kubectl -n longhorn-system get secret minio-secret
# Trigger a manual backup to verify connectivity:
# Longhorn UI → Backup → Create Backup (any volume)
```

**GitHub Webhook (optional — enables instant Flux sync on git push):**

```bash
# Get the webhook path
kubectl -n flux-system get receiver github-webhook \
  --output=jsonpath='{.status.webhookPath}'
# Output looks like: /hook/12ebd1e363c641dc3c2e430ecf3cee2b3c7a5ac9e1234506f6f5f3ce1230e123

# Full webhook URL:
# https://flux-webhook.merox.dev/hook/<path-from-above>

# In GitHub repo → Settings → Webhooks → Add webhook:
#   Payload URL: https://flux-webhook.merox.dev/hook/<path>
#   Content type: application/json
#   Secret: contents of github-push-token.txt
#   Events: Just the push event
```

---

## Phase 3 — Agent (OpenClaw)

> ~10 min. [OpenClaw](https://openclaw.ai) as systemd daemon (Telegram bot → Claude API → kubectl/docker).
> Config template + infra skill live in `agent/` in this repo.

### 3a — Install Node.js 24 + OpenClaw

```bash
# Node.js 24 (required: 22.16+ minimum, 24 recommended)
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs

# Verify
node --version   # must be >= 22.16

# Install OpenClaw globally
sudo npm install -g openclaw@latest

# Verify
openclaw --version
```

### 3b — Configure secrets

```bash
# Create config directory with strict permissions
mkdir -p ~/.openclaw
chmod 700 ~/.openclaw

# Create .env with secrets (never commit this file)
cat > ~/.openclaw/.env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-...        # console.anthropic.com
TELEGRAM_BOT_TOKEN=123456:AAAA...   # @BotFather on Telegram
TELEGRAM_USER_ID=123456789          # your numeric Telegram ID
EOF
chmod 600 ~/.openclaw/.env
```

> **Finding your Telegram user ID:** after setting the bot token, start openclaw,
> send a message to your bot, then run `openclaw logs --follow` and look for `from.id`.

### 3c — Install config + skill from repo

```bash
# Copy config template
cp /srv/kubernetes/infrastructure/agent/openclaw.json ~/.openclaw/openclaw.json
chmod 600 ~/.openclaw/openclaw.json

# Create workspace and install infra skill
mkdir -p ~/.openclaw/workspace/skills
cp -r /srv/kubernetes/infrastructure/agent/skills/infra \
      ~/.openclaw/workspace/skills/infra
```

### 3d — Install systemd daemon

```bash
# Onboard + install as systemd user service
openclaw onboard --install-daemon

# Verify daemon is running
systemctl --user status openclaw-gateway
journalctl --user -u openclaw-gateway -f
```

### 3e — Tailscale Serve (optional but recommended)

Exposes the OpenClaw Control UI on your tailnet only (no public internet):

```bash
# Tailscale Serve routes tailnet HTTPS → local gateway
tailscale serve https / proxy 18789

# Verify
tailscale serve status
# Access Control UI at: https://<hostname>.<tailnet>.ts.net
```

### 3f — Security audit

```bash
openclaw security audit
# Fix any warnings before proceeding
openclaw doctor
```

**Verify:**
```bash
# Telegram: send a message to your bot — it should respond
# Control UI: https://<hostname>.<tailnet>.ts.net (if Tailscale Serve enabled)
systemctl --user status openclaw-gateway
```

---

## Migration Checklist

```
[ ] New server IP updated in: cloudlab-infrastructure/inventories/production/hosts
[ ] Cloudflare DNS A records updated (*.cloud.merox.dev → new IP)
[ ] Phase 1 complete — make health-check passes
[ ] Portainer admin password set
[ ] Garage S3 credentials saved to vault
[ ] AGE key placed at /srv/kubernetes/infrastructure/age.key
[ ] talos/talconfig.yaml updated (node IPs, VIP, installDisk, talosImageURL if changed)
[ ] kubernetes/components/common/cluster-vars.yaml updated (all infrastructure IPs — NFS, router, LB IPs)
[ ] kubernetes/apps/kube-system/cilium/app/networks.yaml updated (subnet cidr, must contain all LB IPs)
[ ] Intel iGPU (i915) present on new hardware — required for Jellyfin HW transcoding
    (if no Intel iGPU: remove gpu.intel.com/i915 from jellyfin helmrelease + disable intel-device-plugin-operator)
[ ] Nodes reachable on port 50000 (nmap verification)
[ ] Phase 2 complete — all nodes Ready, Flux healthy, cilium status OK
[ ] Longhorn volumes restored (task restore:longhorn ran successfully)
[ ] All PVCs bound (kubectl get pvc -A | grep -v Bound → empty)
[ ] Gateway TCP connectivity OK (nmap -p 443 on LB_IP_GATEWAY_INTERNAL + LB_IP_GATEWAY_EXTERNAL)
[ ] DNS resolution OK (dig @LB_IP_K8S_GATEWAY echo.merox.dev)
[ ] Wildcard certificate Ready (kubectl -n network describe certificates)
[ ] Longhorn backup target working (test a manual backup)
[ ] GitHub Webhook configured (optional — for instant Flux sync on git push)
[ ] ~/.openclaw/.env created with ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_USER_ID
[ ] ~/.openclaw/openclaw.json installed from agent/openclaw.json
[ ] infra skill installed at ~/.openclaw/workspace/skills/infra/
[ ] Phase 3 complete — openclaw-gateway daemon running, Telegram bot responds
[ ] openclaw security audit — no warnings
[ ] Old server decommissioned / Tailscale node removed
```

---

## What lives where

| Asset | Location | Backed up? |
|-------|----------|------------|
| K8s manifests + Ansible roles | This git repo | ✅ |
| Kubernetes secrets (SOPS) | Git-encrypted with AGE | ✅ |
| AGE encryption key | `age.key` (gitignored) | ⚠️ Back up manually |
| Vault password | Password manager | ⚠️ Stored externally |
| Ansible vault secrets | `cloudlab-infrastructure/inventories/production/group_vars/all/vault.yml` (encrypted) | ✅ in git |
| Agent config template + skill | `agent/` in this repo | ✅ |
| Agent secrets (`~/.openclaw/.env`) | Only on server | ⚠️ Back up manually |
| Longhorn volumes | Backed up to Garage S3 | ✅ if configured |
| Garage S3 data | Only on VPS disk | ⚠️ No off-site backup |

**The two things to back up manually before decommissioning:**
1. `age.key` — losing this = losing all SOPS-encrypted secrets
2. `~/.openclaw/.env` — Anthropic API key, Telegram tokens
