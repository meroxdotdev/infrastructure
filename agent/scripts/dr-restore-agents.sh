#!/bin/bash
# DR: final step to bring up the agents stack (agents-api + agents-dashboard +
# openclaw-gateway). Run after `make dr-restore` (restores /home/openclaw/.openclaw
# and /srv/dashboard from NAS backups) and after agent/README.md's manual
# steps 1-13 (openclaw user, workspaces, openclaw.json, claude login/onboard,
# dashboard scripts/.env). Idempotent — safe to re-run.
#
# Usage: sudo bash agent/scripts/dr-restore-agents.sh   (run from repo root)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# agents-api: log-tail + run-trigger API consumed by the dashboard frontend
install -d -o openclaw -g openclaw /home/openclaw/agents-api
install -o openclaw -g openclaw -m 664 \
  "$REPO_ROOT/agent/dashboard/agents-api-compose.yml" \
  /home/openclaw/agents-api/docker-compose.yml

# api-server.py is normally restored as part of the `dashboard` backup target
# (make restore-extras) — only redeploy from the repo if it's missing.
if [ ! -f /srv/dashboard/api-server.py ]; then
  install -o openclaw -g openclaw -m 664 \
    "$REPO_ROOT/agent/dashboard/api-server.py" /srv/dashboard/api-server.py
fi

mkdir -p /srv/dashboard/run-triggers
chown openclaw:openclaw /srv/dashboard/run-triggers
chmod 777 /srv/dashboard/run-triggers

(cd /home/openclaw/agents-api && docker compose up -d)
(cd /srv/docker/oracle-cloud/agents-dashboard && docker compose up -d)

XDG_RUNTIME_DIR=/run/user/"$(id -u openclaw)" sudo -u openclaw \
  systemctl --user enable --now openclaw-gateway.service

/usr/local/bin/openclaw-fix-perms

sudo -u openclaw openclaw gateway probe
