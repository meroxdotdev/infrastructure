#!/usr/bin/env bash
# DR pre-flight check — run before "make dr-full"
# Usage: bash scripts/dr-preflight.sh  (from repo root or vps/)
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0

ok()   { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; WARN=$((WARN + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }

# Resolve paths regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VPS_DIR="$REPO_ROOT/vps"

echo ""
echo "DR Pre-flight Check"
echo "==================="
echo "Repo: $REPO_ROOT"
echo ""

echo "[ Vault ]"
if [ -f "$VPS_DIR/.vault_pass" ]; then
    ok ".vault_pass exists"
    if ansible-vault view "$VPS_DIR/inventories/production/group_vars/all/vault.yml" \
        --vault-password-file "$VPS_DIR/.vault_pass" &>/dev/null; then
        ok "vault decrypts successfully"
    else
        fail "vault fails to decrypt — wrong password or corrupted"
    fi
else
    fail ".vault_pass missing at $VPS_DIR/.vault_pass"
fi

echo ""
echo "[ Terraform ]"
TFVARS="$VPS_DIR/terraform/terraform.tfvars"
if [ -f "$TFVARS" ]; then
    ok "terraform.tfvars exists"
    if grep -q "your-hetzner-api-token-here" "$TFVARS"; then
        fail "hcloud_token is still the placeholder value — update terraform.tfvars"
    else
        ok "hcloud_token is set (non-placeholder)"
    fi
    SSH_KEY_PATH=$(grep "ssh_public_key_path" "$TFVARS" | sed 's/.*=\s*"\(.*\)".*/\1/' | tr -d ' ')
    SSH_KEY_EXPANDED="${SSH_KEY_PATH/#\~/$HOME}"
    if [ -f "$SSH_KEY_EXPANDED" ]; then
        ok "SSH public key exists: $SSH_KEY_PATH"
    else
        fail "SSH public key not found: $SSH_KEY_PATH"
    fi
    SSH_PRIVKEY_PATH="${SSH_KEY_PATH%.pub}"
    SSH_PRIVKEY_EXPANDED="${SSH_PRIVKEY_PATH/#\~/$HOME}"
    if [ -f "$SSH_PRIVKEY_EXPANDED" ]; then
        ok "SSH private key exists: $SSH_PRIVKEY_PATH"
    else
        fail "SSH private key not found: $SSH_PRIVKEY_PATH — Ansible won't be able to connect after terraform-apply"
    fi
else
    fail "terraform.tfvars missing — copy terraform.tfvars.example and fill in values"
fi

echo ""
echo "[ Critical secrets ]"
if [ -f "$REPO_ROOT/age.key" ]; then
    ok "age.key exists at $REPO_ROOT/age.key"
else
    fail "age.key missing — K8s SOPS secrets will be unrecoverable without it"
fi

OPENCLAW_ENV="/home/openclaw/.openclaw/.env"
if [ -f "$OPENCLAW_ENV" ]; then
    ok "openclaw .env exists at $OPENCLAW_ENV"
else
    warn "openclaw .env not found at $OPENCLAW_ENV — agents won't work after Phase 3 without it"
fi

echo ""
echo "[ Tailscale auth key ]"
if [ -f "$VPS_DIR/.vault_pass" ]; then
    TS_KEY=$(ansible-vault view "$VPS_DIR/inventories/production/group_vars/all/vault.yml" \
        --vault-password-file "$VPS_DIR/.vault_pass" 2>/dev/null \
        | grep "vault_tailscale_auth_key" | awk '{print $2}' | tr -d '"'"'" || true)
    if [ -z "$TS_KEY" ]; then
        fail "vault_tailscale_auth_key not found in vault"
    elif echo "$TS_KEY" | grep -qi "placeholder\|changeme\|your"; then
        fail "vault_tailscale_auth_key looks like a placeholder value"
    else
        KEY_PREFIX="${TS_KEY:0:12}..."
        warn "vault_tailscale_auth_key is set ($KEY_PREFIX) — verify it has NOT expired at tailscale.com/admin/settings/keys (90-day keys expire silently)"
    fi
fi

echo ""
echo "[ Ansible dependencies ]"
COLLECTIONS_DIR="$VPS_DIR/collections"
if [ -d "$COLLECTIONS_DIR" ] && [ "$(ls -A "$COLLECTIONS_DIR" 2>/dev/null)" ]; then
    ok "Ansible collections present at $COLLECTIONS_DIR"
else
    warn "Ansible collections directory empty — run: cd vps && make install"
fi

echo ""
echo "[ K8s prerequisites (Phase 2) ]"
if command -v task &>/dev/null; then
    ok "task (Taskfile runner) available"
else
    warn "task not found — needed for Phase 2 (install via mise)"
fi
if command -v talosctl &>/dev/null; then
    ok "talosctl available"
else
    warn "talosctl not found — needed for Phase 2 (install via mise)"
fi
if command -v kubectl &>/dev/null; then
    ok "kubectl available"
else
    warn "kubectl not found — needed for Phase 2 (install via mise)"
fi

echo ""
echo "[ Agents prerequisites (Phase 3) ]"
if command -v node &>/dev/null; then
    NODE_VER=$(node --version 2>/dev/null)
    ok "Node.js available: $NODE_VER"
else
    warn "Node.js not installed — needed for Phase 3 (curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -)"
fi
if command -v openclaw &>/dev/null; then
    ok "openclaw CLI available"
else
    warn "openclaw not installed — needed for Phase 3 (sudo npm install -g openclaw@latest)"
fi

echo ""
echo "========================================"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${YELLOW}WARN: $WARN${NC}  ${RED}FAIL: $FAIL${NC}"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}Pre-flight FAILED — fix the errors above before running make dr-full${NC}"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo -e "${YELLOW}Pre-flight passed with warnings — review them above before proceeding${NC}"
    exit 0
else
    echo -e "${GREEN}Pre-flight OK — safe to run: make dr-full${NC}"
    exit 0
fi
