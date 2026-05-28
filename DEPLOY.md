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

> ~15 min. Sets up: SSH hardening, fail2ban, Docker, Tailscale, Traefik, Pi-hole + Unbound,
> Portainer, Homepage, Joplin + Postgres, Uptime Kuma, Guacamole, Glances, Authentik SSO,
> Garage S3, Netdata, Beszel, Dozzle. Ansible runs **autonomously on the server via cloud-init** — no external runner needed.

### Option A — Terraform + cloud-init (recommended, fully automated)

> **Prerequisite:** `vault_tailscale_auth_key` must be valid (Tailscale keys expire).
> Generate a new one at `tailscale.com/admin/settings/keys` (Reusable, Ephemeral OFF), then:
> ```bash
> cd cloudlab-infrastructure/ && make vault-edit   # update vault_tailscale_auth_key
> git add inventories/production/group_vars/all/vault.yml && git commit -m "fix: update tailscale auth key" && git push
> ```

```bash
cd cloudlab-infrastructure/

# First time only
make terraform-init

# Provision Hetzner server — cloud-init deploys everything autonomously on the server
make dr-full
```

Reads vault password from `.vault_pass` automatically — no prompt.
`dr-full` = `terraform apply` (provisions server) → cloud-init clones repo + runs full Ansible on the server (~15 min).
Tailscale and Let's Encrypt certs reconnect automatically.

Monitor progress:
```bash
ssh -i ~/.ssh/cloudlab_dr_test root@<IP> 'tail -f /var/log/cloudlab-setup.log'
```

After deploy completes, restore Joplin and Authentik data:
```bash
make restore
# Interactive: asks which service, optional remote backup host (IP/SSH key), then restores
```

### Option B — Existing server / manual provisioning

> **Note:** The inventory uses `ansible_connection=local` — Ansible must run **on the server itself**, not from a remote machine.

```bash
# 1. SSH into the server, then clone the repo there
ssh root@<SERVER_IP>
git clone https://github.com/meroxdotdev/cloudlab-merox /opt/cloudlab-merox
cd /opt/cloudlab-merox
echo "<vault-password>" > .vault_pass && chmod 600 .vault_pass

# 2. Install Ansible collections
make install

# 3. Full deploy
make setup
```

> **DNS note:** all web traffic goes through Cloudflare Tunnel — no A records to update.
> The tunnel reconnects automatically with the same token on the new server.
> Tailscale also reconnects automatically via the auth key in vault.

**Post-deploy manual steps:**

```bash
# Portainer: set admin password at https://portainer.cloud.merox.dev
# Guacamole: change default credentials (guacadmin / guacadmin) immediately
# Pi-hole: verify DNS at https://pihole.cloud.merox.dev/admin
# Joplin: clients will sync automatically once server is up

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

## Phase 3 — Agents (OpenClaw)

> ~15 min. [OpenClaw](https://openclaw.ai) running as dedicated `openclaw` user (non-root).
> 5 specialized agents: news briefing, blog, design, infra, backup/costs.
> All config templates live in `agent/` in this repo.

### 3a — Install Node.js 24 + OpenClaw

```bash
# Node.js 24 (required: 22.16+ minimum, 24 recommended)
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs

node --version   # must be >= 22.16
sudo npm install -g openclaw@latest
openclaw --version
```

### 3b — Create dedicated openclaw user

```bash
sudo useradd -m -s /bin/bash -d /home/openclaw -c "OpenClaw Service Account" openclaw
sudo usermod -aG docker openclaw
sudo loginctl enable-linger openclaw

# Sudoers — specific commands only, no full sudo
sudo cp /srv/kubernetes/infrastructure/agent/scripts/sudoers-openclaw /etc/sudoers.d/openclaw
sudo chmod 440 /etc/sudoers.d/openclaw
sudo visudo -c  # verify
```

### 3c — Set up infra access for openclaw user

```bash
sudo -u openclaw mkdir -p /home/openclaw/.kube /home/openclaw/.talos

sudo cp /srv/kubernetes/infrastructure/kubeconfig /home/openclaw/.kube/config
sudo cp /srv/kubernetes/infrastructure/talos/clusterconfig/talosconfig /home/openclaw/.talos/config

sudo chown openclaw:openclaw /home/openclaw/.kube/config /home/openclaw/.talos/config
sudo chmod 600 /home/openclaw/.kube/config /home/openclaw/.talos/config
```

### 3d — Authenticate Claude Code + configure OpenClaw auth

This step sets up Claude Pro subscription access (no separate API key needed) and generates the gateway auth token.

```bash
# 1. Authenticate Claude Code CLI as openclaw user
sudo -u openclaw claude login
# Follow the OAuth flow in browser

# 2. Run OpenClaw onboard to wire up Claude CLI auth and generate gateway token
sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  openclaw onboard --non-interactive \
  --mode local \
  --auth-choice anthropic-cli \
  --skip-bootstrap \
  --skip-skills \
  --skip-daemon \
  --accept-risk

# This writes agentRuntime: { id: "claude-cli" } and a gateway.auth.token to openclaw.json
```

> **What this does:** Configures OpenClaw to use Claude Code's OAuth session (Claude Pro subscription) instead of an Anthropic API key. No per-token billing.

### 3e — Configure Telegram secrets

The onboard generated `~/.openclaw/openclaw.json`. Overlay it with the repo template (keeping the generated auth token):

```bash
# Copy Telegram config into the generated file
sudo -u openclaw python3 << 'EOF'
import json

with open('/home/openclaw/.openclaw/openclaw.json') as f:
    cfg = json.load(f)

# Set Telegram channel (fill in your values)
cfg['channels'] = {
    'telegram': {
        'botToken': 'YOUR_TELEGRAM_BOT_TOKEN',   # from @BotFather
        'allowFrom': ['YOUR_TELEGRAM_USER_ID']    # from @userinfobot
    }
}

with open('/home/openclaw/.openclaw/openclaw.json', 'w') as f:
    json.dump(cfg, f, indent=2)
print('Done')
EOF
```

> **Finding your Telegram user ID:** send `/start` to **@userinfobot** on Telegram.

### 3f — Install agent workspaces

```bash
AGENT_DIR=/srv/kubernetes/infrastructure/agent/workspaces

sudo -u openclaw cp -r $AGENT_DIR/news /home/openclaw/.openclaw/workspace
sudo -u openclaw cp -r $AGENT_DIR/blog /home/openclaw/.openclaw/workspace-blog
sudo -u openclaw cp -r $AGENT_DIR/design /home/openclaw/.openclaw/workspace-design
sudo -u openclaw cp -r $AGENT_DIR/infra /home/openclaw/.openclaw/workspace-infra
sudo -u openclaw cp -r $AGENT_DIR/costs /home/openclaw/.openclaw/workspace-costs

# Create runtime memory dirs
sudo -u openclaw mkdir -p /home/openclaw/.openclaw/workspace/memory
sudo -u openclaw mkdir -p /home/openclaw/.openclaw/workspace-infra/memory
```

### 3g — Set up dashboard

```bash
# Create dashboard directory
sudo mkdir -p /srv/dashboard/data
sudo chown openclaw:openclaw /srv/dashboard /srv/dashboard/data

# Initialize empty data files
echo '{"news":{"lastRun":null,"status":"pending","summary":"Not yet run"},"blog":{"lastRun":null,"status":"pending","summary":"Not yet run"},"design":{"lastRun":null,"status":"pending","summary":"Not yet run"},"infra":{"lastRun":null,"status":"pending","summary":"Not yet run"},"costs":{"lastRun":null,"status":"pending","summary":"Not yet run"}}' \
  | sudo -u openclaw tee /srv/dashboard/data/agents.json > /dev/null

# Copy dashboard HTML (from this repo)
sudo cp /srv/kubernetes/infrastructure/agent/dashboard/index.html /srv/dashboard/
sudo cp /srv/kubernetes/infrastructure/agent/dashboard/news.html /srv/dashboard/ 2>/dev/null || true
sudo chown -R openclaw:openclaw /srv/dashboard

# Start nginx container
cd /srv/docker/agents-dashboard && docker compose up -d
# Dashboard available at: https://agents.cloud.merox.dev
```

### 3h — Install systemd user service

```bash
sudo -u openclaw mkdir -p /home/openclaw/.config/systemd/user
sudo cp /srv/kubernetes/infrastructure/agent/scripts/openclaw-gateway.service \
        /home/openclaw/.config/systemd/user/
sudo chown openclaw:openclaw /home/openclaw/.config/systemd/user/openclaw-gateway.service

XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) sudo -u openclaw systemctl --user daemon-reload
XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) sudo -u openclaw systemctl --user enable --now openclaw-gateway.service

# Verify
XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) sudo -u openclaw systemctl --user status openclaw-gateway
```

### 3i — Security audit

```bash
sudo -u openclaw openclaw doctor
sudo -u openclaw openclaw status
```

**Verify:**
```bash
# Telegram: send "hello" to your bot — news agent should respond
# Dashboard: https://agents.cloud.merox.dev
XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) sudo -u openclaw systemctl --user status openclaw-gateway
```

---

## Migration Checklist

```
[ ] vault_tailscale_auth_key valid and pushed before dr-full
[ ] Phase 1 complete — make dr-full finished, all containers up (make health-check)
[ ] Joplin + Authentik data restored — make restore
[ ] Tailscale connected (verify: ssh root@<IP> tailscale status)
[ ] Portainer admin password set
[ ] Guacamole default credentials changed (guacadmin / guacadmin → new password)
[ ] Joplin clients syncing to new server
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
[ ] openclaw user created, in docker group, linger enabled
[ ] sudoers-openclaw installed at /etc/sudoers.d/openclaw
[ ] kubeconfig + talosconfig copied to /home/openclaw/.kube/ and /home/openclaw/.talos/
[ ] /home/openclaw/.openclaw/openclaw.json configured (Telegram token + user ID filled in)
[ ] claude login done as openclaw user (Claude Pro OAuth)
[ ] All 5 workspaces installed (news, blog, design, infra, costs)
[ ] /srv/dashboard/ created with data/ subdirectory, agents.json initialized
[ ] agents-dashboard nginx container running (docker ps | grep agents-dashboard)
[ ] openclaw-gateway systemd user service enabled + running as openclaw user
[ ] https://agents.cloud.merox.dev accessible and showing command center
[ ] Telegram bot responds to messages
[ ] openclaw doctor — no warnings
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
