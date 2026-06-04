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
> Garage S3, Netdata, Beszel, Dozzle.
>
> **How it works:** Terraform provisions the Hetzner server (cloud-init installs python3 + creates dirs).
> `make dr-full` then runs Ansible from your local machine over SSH to deploy all services.
> This differs from the Oracle Cloud production setup, where Ansible runs locally on the server
> (inventory uses `ansible_connection=local` since OCI blocks SSH from external IPs).

### Option A — Terraform + Hetzner (recommended for DR)

> **Prerequisite:** `vault_tailscale_auth_key` must be valid (Tailscale keys expire after 90 days).
> Verify at `tailscale.com/admin/settings/keys` before starting. Then:
> ```bash
> cd vps/ && make vault-edit   # update vault_tailscale_auth_key
> git add inventories/production/group_vars/all/vault.yml && git commit -m "fix: update tailscale auth key" && git push
> ```

```bash
cd vps/

# First time only
make terraform-init

# Run pre-flight checks, then provision + deploy
make dr-full
# dr-full = dr-preflight + terraform apply + SSH poll until ready + Ansible setup
```

Reads vault password from `.vault_pass` automatically — no prompt.
Tailscale and Let's Encrypt certs connect automatically.

After deploy completes, restore Joplin and Authentik data:
```bash
make restore
# Interactive: asks which service, optional remote backup host (IP/SSH key), then restores
```

Verify Phase 1 is healthy:
```bash
make dr-verify-phase1   # run on the VPS (or: bash scripts/dr-verify.sh --phase 1)
```

**IMPORTANT — before Phase 2:** extract Garage S3 credentials and save to vault:
```bash
make garage-extract-creds   # run on the VPS — extracts keys + updates vault automatically
```

### Option B — Existing server / manual provisioning

> **Note:** The inventory uses `ansible_connection=local` — Ansible must run **on the server itself**, not from a remote machine.

```bash
# 1. SSH into the server, then clone the infrastructure repo
ssh root@<SERVER_IP>
git clone https://github.com/meroxdotdev/infrastructure /opt/infrastructure
cd /opt/infrastructure/vps
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

### Option A — New Proxmox VMs via Terraform (recommended for DR simulation)

```bash
cd /srv/kubernetes/infrastructure/

# 1. Install tools
mise trust && mise install

# 2. Place AGE key
cp /path/to/age.key ./age.key

# 3. Create Proxmox API token for Terraform:
#    Proxmox → Datacenter → API Tokens → Add
#    User: root@pam, Token name: terraform, Privilege separation: OFF
#    Save the secret shown once.

# 4. Configure Terraform for Proxmox VMs
cp talos/terraform/terraform.tfvars.example talos/terraform/terraform.tfvars
# Edit: fill in proxmox_token_id and proxmox_token_secret

# 5. Create 3 Talos VMs on Proxmox (downloads ISO automatically)
task dr:create-vms
# Wait 30s for VMs to boot into Talos maintenance mode
# Verify: nmap -Pn -n -p 50000 10.57.57.90 10.57.57.92 10.57.57.94 -vv | grep Discovered

# 6. Patch talconfig.yaml with DR IPs + MACs (auto-reads Terraform outputs)
task dr:patch-talconfig

# 7. Bootstrap Talos
task bootstrap:talos
git add -A && git commit -m "chore: add secrets" && git push
```

After DR test, restore prod config and destroy VMs:
```bash
task dr:restore-talconfig
task dr:destroy-vms
```

### Option B — Existing hardware / manual IP assignment

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
```

### Shared steps (both Option A and Option B)

```bash
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
# One-shot: bash scripts/dr-verify.sh --phase 2
# Or manually:

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

> ~15 min. 7 specialized agents running as dedicated `openclaw` user (non-root).
> All config templates live in `agent/` in this repo.

**Full setup guide: [agent/README.md](agent/README.md)**

The agent README is the single source of truth for this phase. It covers:
- Node.js 24 + OpenClaw install
- `openclaw` user creation + sudoers
- `sudoers-fix-perms` + `openclaw-fix-perms` scripts
- infra access (kubeconfig, talosconfig)
- Claude Code OAuth + OpenClaw onboard
- Telegram config
- All 7 workspace installs (news, blog, design, infra, costs, dashboard, orchestrator)
- Dashboard setup + crontab
- systemd user service

**Verify when done:**
```bash
# One-shot: bash scripts/dr-verify.sh --phase 3
# Or manually:
sudo -u openclaw openclaw doctor
sudo -u openclaw openclaw status
# Telegram: send "hello" to your bot — news agent should respond
# Dashboard: https://agents.cloud.merox.dev
```

---

## Migration Checklist

```
[ ] vault_tailscale_auth_key valid and pushed before dr-full
[ ] make dr-preflight — all checks PASS (no FAIL)
[ ] Phase 1 complete — make dr-full finished, all containers up (make dr-verify-phase1)
[ ] make garage-extract-creds — Garage S3 credentials saved to vault (REQUIRED before Phase 2)
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
[ ] Phase 2 complete — all nodes Ready, Flux healthy, cilium status OK (make dr-verify-phase2)
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
[ ] All 9 workspaces installed (news, blog, design, infra, costs, dashboard, orchestrator, renovate, repo)
[ ] openclaw doctor — no warnings (make dr-verify-phase3)
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
| Ansible vault secrets | `vps/inventories/production/group_vars/all/vault.yml` (encrypted) | ✅ in git |
| Agent config template + skill | `agent/` in this repo | ✅ |
| Agent secrets (`~/.openclaw/.env`) | Only on server | ⚠️ Back up manually |
| Longhorn volumes | Backed up to Garage S3 | ✅ if configured |
| Garage S3 data | Only on VPS disk | ⚠️ No off-site backup |

**The two things to back up manually before decommissioning:**
1. `age.key` — losing this = losing all SOPS-encrypted secrets
2. `~/.openclaw/.env` — Anthropic API key, Telegram tokens
