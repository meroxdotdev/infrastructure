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
├── openclaw.json               # main config (Telegram token here)
├── workspace/                  # news agent workspace
│   ├── AGENTS.md
│   ├── SOUL.md
│   ├── TOOLS.md
│   ├── IDENTITY.md
│   ├── USER.md
│   ├── HEARTBEAT.md
│   └── memory/
├── workspace-blog/             # blog agent workspace
├── workspace-design/           # design agent workspace
├── workspace-infra/            # infra agent workspace
└── workspace-costs/            # costs/backup agent workspace

/home/openclaw/.kube/config     # kubeconfig (from this repo)
/home/openclaw/.talos/config    # talosconfig (from this repo)

/srv/dashboard/                 # web dashboard (served by nginx container)
├── index.html                  # command center
├── news.html                   # news briefing (written by news agent)
└── data/
    ├── agents.json             # agent status (written by agents)
    ├── news.json               # news data (written by news agent)
    ├── infra.json              # infra status (written by infra agent)
    └── backup.json             # backup status (written by costs agent)

/srv/docker/agents-dashboard/   # nginx container docker-compose
```

## Disaster recovery / new server setup

```bash
# 1. Install Node.js and OpenClaw
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g openclaw

# 2. Create openclaw user
sudo useradd -m -s /bin/bash -d /home/openclaw -c "OpenClaw Service Account" openclaw
sudo usermod -aG docker openclaw
sudo loginctl enable-linger openclaw

# 3. Copy sudoers
sudo cp agent/scripts/sudoers-openclaw /etc/sudoers.d/openclaw
sudo chmod 440 /etc/sudoers.d/openclaw

# 4. Copy kubeconfig and talosconfig
sudo -u openclaw mkdir -p /home/openclaw/.kube /home/openclaw/.talos
sudo cp infrastructure/kubeconfig /home/openclaw/.kube/config
sudo cp infrastructure/talos/clusterconfig/talosconfig /home/openclaw/.talos/config
sudo chown openclaw:openclaw /home/openclaw/.kube/config /home/openclaw/.talos/config
sudo chmod 600 /home/openclaw/.kube/config /home/openclaw/.talos/config

# 5. Copy workspace files and config
sudo -u openclaw cp -r agent/workspaces/news /home/openclaw/.openclaw/workspace
sudo -u openclaw cp -r agent/workspaces/blog /home/openclaw/.openclaw/workspace-blog
sudo -u openclaw cp -r agent/workspaces/design /home/openclaw/.openclaw/workspace-design
sudo -u openclaw cp -r agent/workspaces/infra /home/openclaw/.openclaw/workspace-infra
sudo -u openclaw cp -r agent/workspaces/costs /home/openclaw/.openclaw/workspace-costs

# 6. Create openclaw.json (fill in Telegram token + API key)
sudo -u openclaw cp agent/openclaw.json.example /home/openclaw/.openclaw/openclaw.json
sudo nano /home/openclaw/.openclaw/openclaw.json  # fill in secrets

# 7. Authenticate Claude Code as openclaw user
sudo -u openclaw claude login

# 8. Install and start systemd service
sudo -u openclaw mkdir -p /home/openclaw/.config/systemd/user
sudo cp agent/scripts/openclaw-gateway.service /home/openclaw/.config/systemd/user/
XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) sudo -u openclaw systemctl --user daemon-reload
XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) sudo -u openclaw systemctl --user enable --now openclaw-gateway.service

# 9. Start dashboard container
cd /srv/docker/agents-dashboard && docker compose up -d
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
