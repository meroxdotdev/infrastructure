# OpenClaw Agents — merox.dev Infrastructure

Self-hosted AI agent setup using [OpenClaw](https://openclaw.ai) for the merox.dev homelab.

## Architecture

```
oracle-cloud VPS
  └── openclaw user (non-root, docker group)
        └── openclaw gateway (systemd user service, port 18789, loopback only)
              ├── news agent    — daily morning briefing in Romanian
              ├── blog agent    — content analysis & drafting for merox.dev
              ├── design agent  — UX/design recommendations for merox.dev
              ├── infra agent   — K8s cluster + VPS security & stability
              └── costs agent   — backup verification & resource tracking

agents-dashboard (nginx container via Traefik)
  └── https://agents.cloud.merox.dev
        ├── /index.html     — command center (all agents status)
        └── /news.html      — latest news briefing
```

## Channels

- **Telegram** — primary interface, bot with strict allowlist
- **Gateway** — loopback-only (127.0.0.1:18789), remote access via Tailscale

## Infrastructure access (openclaw user)

| Tool | Access method |
|------|---------------|
| kubectl | `/home/openclaw/.kube/config` (copy of infra kubeconfig) |
| talosctl | `/home/openclaw/.talos/config` (copy of talosconfig) |
| docker | `docker` group membership |
| flux | direct binary, uses kubeconfig |

## Sudoers (specific, no full sudo)

```
openclaw ALL=(ALL) NOPASSWD: /usr/bin/kubectl
openclaw ALL=(ALL) NOPASSWD: /usr/bin/flux
openclaw ALL=(ALL) NOPASSWD: /usr/bin/talosctl
openclaw ALL=(ALL) NOPASSWD: /bin/systemctl status *
openclaw ALL=(ALL) NOPASSWD: /usr/bin/node
```

## Directory structure on VPS

```
/home/openclaw/.openclaw/
├── openclaw.json                    # main config (600, openclaw:openclaw)
├── workspace/                       # news agent (default entry point)
│   ├── AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md, USER.md, HEARTBEAT.md
│   └── memory/
├── workspace-blog/                  # blog agent
│   ├── AGENTS.md, SOUL.md, USER.md, HEARTBEAT.md
│   └── memory/
├── workspace-design/                # design agent (on-demand only)
│   ├── AGENTS.md, SOUL.md, USER.md
│   └── memory/
├── workspace-infra/                 # infra agent
│   ├── AGENTS.md, SOUL.md, TOOLS.md, USER.md, HEARTBEAT.md
│   └── memory/
├── workspace-costs/                 # costs & backup agent
│   ├── AGENTS.md, SOUL.md, TOOLS.md, USER.md, HEARTBEAT.md
│   └── memory/
├── workspace-dashboard/             # dashboard improvement agent
│   ├── AGENTS.md, SOUL.md
│   └── memory/
└── workspace-orchestrator/          # meta-agent: monitors all others
    ├── AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md
    └── memory/

/home/openclaw/.kube/config          # kubeconfig (from this repo)
/home/openclaw/.talos/config         # talosconfig (from this repo)
/usr/local/bin/talosctl              # system-wide binary (mise installs per-user, not accessible)
/usr/local/bin/openclaw-fix-perms    # fixes root ownership after Claude Code sessions

/srv/dashboard/                      # web dashboard (nginx container)
├── index.html                       # command center (written by dashboard agent)
├── news.html                        # news briefing (written by news agent)
├── update-infra.sh                  # bash: updates infra.json every 5 min (root-owned)
├── update-backup.sh                 # bash: updates backup.json every 30 min (root-owned)
├── update-news.sh                   # bash: pre-fetches GitHub releases (root-owned)
└── data/
    ├── agents.json                  # all agents write their own key here
    ├── news.json                    # news agent
    ├── infra.json                   # ← OWNED BY update-infra.sh — agents NEVER write this
    ├── infra-extended.json          # infra agent (TLS days, flux times, etc.)
    ├── backup.json                  # costs agent + update-backup.sh
    ├── orchestrator.json            # orchestrator agent
    └── proposals.json               # orchestrator agent

/srv/docker/agents-dashboard/        # nginx container docker-compose
/srv/merox/src/content/blog/         # blog drafts (blog agent writes here)
```

## Disaster recovery / new server setup

```bash
# 1. Install Node.js 24 + OpenClaw
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g openclaw@latest

# 2. Create openclaw user
sudo useradd -m -s /bin/bash -d /home/openclaw -c "OpenClaw Service Account" openclaw
sudo usermod -aG docker openclaw
sudo loginctl enable-linger openclaw

# 3. Copy sudoers (two files)
sudo cp agent/scripts/sudoers-openclaw /etc/sudoers.d/openclaw
sudo chmod 440 /etc/sudoers.d/openclaw
sudo cp agent/scripts/sudoers-fix-perms /etc/sudoers.d/openclaw-fix-perms
sudo chmod 440 /etc/sudoers.d/openclaw-fix-perms

# 4. Install fix-perms script + root crontab entry
sudo cp agent/scripts/openclaw-fix-perms /usr/local/bin/
sudo chmod 755 /usr/local/bin/openclaw-fix-perms
(sudo crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/openclaw-fix-perms") | sudo crontab -

# 5. Install talosctl system-wide
# mise installs talosctl in root's home (~/.local/share/mise/...) which openclaw can't access
# Copy the binary to /usr/local/bin so all users can run it
TALOS_VER=$(talosctl version --client 2>/dev/null | grep Tag | awk '{print $2}' | tr -d 'v')
sudo find ~/.local/share/mise/installs/aqua-siderolabs-talos -name talosctl -newer /tmp \
  | sort -t/ -k9 -V | tail -1 | xargs -I{} sudo cp {} /usr/local/bin/talosctl
sudo chmod 755 /usr/local/bin/talosctl

# 6. Copy kubeconfig and talosconfig
sudo -u openclaw mkdir -p /home/openclaw/.kube /home/openclaw/.talos
sudo cp kubeconfig /home/openclaw/.kube/config
sudo cp talos/clusterconfig/talosconfig /home/openclaw/.talos/config
sudo chown openclaw:openclaw /home/openclaw/.kube/config /home/openclaw/.talos/config
sudo chmod 600 /home/openclaw/.kube/config /home/openclaw/.talos/config

# 7. Copy all 7 workspace directories + create memory dirs
sudo -u openclaw mkdir -p /home/openclaw/.openclaw
WDIR=/home/openclaw/.openclaw
REPO_WS=$(pwd)/agent/workspaces
sudo -u openclaw cp -r $REPO_WS/news      $WDIR/workspace
sudo -u openclaw cp -r $REPO_WS/blog      $WDIR/workspace-blog
sudo -u openclaw cp -r $REPO_WS/design    $WDIR/workspace-design
sudo -u openclaw cp -r $REPO_WS/infra     $WDIR/workspace-infra
sudo -u openclaw cp -r $REPO_WS/costs     $WDIR/workspace-costs
sudo -u openclaw cp -r $REPO_WS/dashboard $WDIR/workspace-dashboard
sudo -u openclaw cp -r $REPO_WS/orchestrator $WDIR/workspace-orchestrator
for ws in workspace workspace-blog workspace-design workspace-infra \
          workspace-costs workspace-dashboard workspace-orchestrator; do
  sudo -u openclaw mkdir -p $WDIR/$ws/memory
done

# 8. Configure openclaw.json (fill in secrets)
sudo cp agent/openclaw.json.example /home/openclaw/.openclaw/openclaw.json
sudo chown openclaw:openclaw /home/openclaw/.openclaw/openclaw.json
sudo chmod 600 /home/openclaw/.openclaw/openclaw.json
# Edit: fill in botToken and allowFrom (Telegram user ID)
sudo -u openclaw nano /home/openclaw/.openclaw/openclaw.json

# 9. Authenticate Claude Code + wire up OpenClaw runtime
sudo -u openclaw claude login   # opens browser link for OAuth
sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  openclaw onboard --non-interactive \
  --mode local \
  --auth-choice anthropic-cli \
  --skip-bootstrap \
  --skip-daemon \
  --accept-risk
# After onboard, verify openclaw.json still has your Telegram config (onboard may reset it)

# 10. Install systemd user service
sudo -u openclaw mkdir -p /home/openclaw/.config/systemd/user
sudo cp agent/scripts/openclaw-gateway.service /home/openclaw/.config/systemd/user/
sudo chown openclaw:openclaw /home/openclaw/.config/systemd/user/openclaw-gateway.service
XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) sudo -u openclaw systemctl --user daemon-reload
XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) sudo -u openclaw systemctl --user enable --now openclaw-gateway.service

# 11. Install openclaw user crontab
sudo -u openclaw crontab agent/scripts/openclaw-crontab

# 12. Initialize data files + start dashboard
sudo mkdir -p /srv/dashboard/data
sudo chown openclaw:openclaw /srv/dashboard /srv/dashboard/data
echo '{"pending":[],"history":[]}' | sudo -u openclaw tee /srv/dashboard/data/proposals.json
cd /srv/docker/agents-dashboard && docker compose up -d
/usr/local/bin/openclaw-fix-perms  # ensure all permissions are correct from the start
```

## Verify everything is working

```bash
sudo -u openclaw openclaw doctor
sudo -u openclaw openclaw status
sudo -u openclaw openclaw security audit
# Check gateway is reachable
sudo -u openclaw openclaw gateway probe
# Trigger infra data update
sudo -u openclaw bash /srv/dashboard/update-infra.sh
```

## Security notes

- Gateway is loopback-only; remote access via Tailscale SSH tunnel only
- Telegram bot uses strict `allowFrom` whitelist (only your user ID)
- Agent cannot read: `age.key`, `*.sops.yaml`, `.env` files, private keys
- No destructive ops without explicit confirmation
- Dashboard at `agents.cloud.merox.dev` is protected by Authentik

## OpenClaw version

Installed: `openclaw --version`
Docs: https://docs.openclaw.ai
