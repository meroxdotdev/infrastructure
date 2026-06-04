#!/usr/bin/env bash
# DR verification — run after each phase to confirm it succeeded
# Usage:
#   bash scripts/dr-verify.sh --phase 1   (VPS — run on the VPS)
#   bash scripts/dr-verify.sh --phase 2   (K8s — run from local machine with kubectl)
#   bash scripts/dr-verify.sh --phase 3   (Agents — run on the VPS)
#   bash scripts/dr-verify.sh --phase all (runs all — assumes you're on the VPS)
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0

ok()    { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; WARN=$((WARN + 1)); }
fail()  { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }
header(){ echo -e "\n${CYAN}$1${NC}"; }

container_running() {
    local name="$1"
    if docker ps --filter "name=^${name}$" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -q "^${name}$"; then
        ok "container $name running"
    else
        fail "container $name NOT running (docker ps | grep $name)"
    fi
}

http_ok() {
    local label="$1" url="$2"
    if curl -sf --max-time 5 "$url" &>/dev/null; then
        ok "$label responds"
    else
        fail "$label not responding ($url)"
    fi
}

PHASE="${1:-}"
if [ -z "$PHASE" ]; then
    PHASE="--phase"
    shift 2>/dev/null || true
fi

# Parse --phase argument
case "$*" in
    *"--phase 1"*) RUN_PHASE=1 ;;
    *"--phase 2"*) RUN_PHASE=2 ;;
    *"--phase 3"*) RUN_PHASE=3 ;;
    *"--phase all"*) RUN_PHASE=all ;;
    *) echo "Usage: $0 --phase 1|2|3|all"; exit 1 ;;
esac

echo ""
echo "DR Verify — Phase $RUN_PHASE"
echo "============================="

# ---------------------------------------------------------------------------
# Phase 1 — VPS
# ---------------------------------------------------------------------------
verify_phase1() {
    header "Phase 1: VPS Containers"

    # Main compose (docker-compose.yml in /srv/docker/oracle-cloud/)
    container_running "homepage"
    container_running "glances"
    container_running "portainer"
    container_running "pihole"
    container_running "unbound"
    container_running "traefik"

    header "Phase 1: VPS Containers (sub-composes)"
    container_running "authentik-server"
    container_running "authentik-worker"
    container_running "authentik-postgresql"
    container_running "garage"
    container_running "uptime-kuma"
    container_running "guacamole"
    container_running "dozzle"

    # Joplin managed by Ansible (not in main compose)
    if docker ps --filter "name=joplin" --format "{{.Names}}" 2>/dev/null | grep -q "joplin"; then
        ok "container joplin running"
    else
        warn "container joplin not found — managed by Ansible (may need: cd vps && make joplin-setup)"
    fi

    header "Phase 1: Service health"

    # Traefik API
    http_ok "Traefik API" "http://localhost:8080/ping"

    # Pi-hole DNS
    if dig @localhost google.com +short +time=3 &>/dev/null; then
        ok "Pi-hole DNS resolves"
    else
        fail "Pi-hole DNS not responding"
    fi

    # Homepage
    http_ok "Homepage" "http://localhost:3000"

    # Joplin sync API
    http_ok "Joplin API" "http://localhost:22300/api/ping"

    # Authentik health
    if curl -sf --max-time 5 "http://localhost:9000/-/health/live/" &>/dev/null || \
       curl -sf --max-time 5 "http://localhost:9000/if/user/" &>/dev/null; then
        ok "Authentik responds"
    else
        fail "Authentik not responding (port 9000)"
    fi

    # Garage S3 API
    http_ok "Garage S3 API" "http://localhost:3900/health"

    # Portainer API
    if curl -sf --max-time 5 "http://localhost:9000/api/system/status" &>/dev/null || \
       curl -sf --max-time 5 "http://localhost:9443/api/system/status" &>/dev/null; then
        ok "Portainer API responds"
    else
        warn "Portainer API not responding — may need admin password set first"
    fi

    header "Phase 1: System"
    DISK=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$DISK" -lt 80 ]; then
        ok "Disk usage: ${DISK}%"
    else
        warn "Disk usage HIGH: ${DISK}%"
    fi

    if tailscale status &>/dev/null 2>&1; then
        ok "Tailscale connected"
    else
        fail "Tailscale not connected (tailscale status)"
    fi

    # Cloudflare tunnel (check cloudflared container)
    if docker ps --filter "name=cloudflared" --format "{{.Names}}" 2>/dev/null | grep -q "cloudflared"; then
        ok "Cloudflare tunnel container running"
    else
        warn "cloudflared container not found — public access via Traefik+Cloudflare may be down"
    fi
}

# ---------------------------------------------------------------------------
# Phase 2 — K8s
# ---------------------------------------------------------------------------
verify_phase2() {
    header "Phase 2: K8s Nodes"
    if ! command -v kubectl &>/dev/null; then
        fail "kubectl not found — install via mise"
        return
    fi

    NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready " || true)
    if [ -z "$NOT_READY" ]; then
        NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        ok "All $NODE_COUNT nodes Ready"
    else
        fail "Nodes not Ready:\n$NOT_READY"
    fi

    header "Phase 2: Flux"
    BROKEN_KS=$(kubectl get kustomizations -A --no-headers 2>/dev/null | grep -v " True " || true)
    if [ -z "$BROKEN_KS" ]; then
        ok "All Flux kustomizations reconciled"
    else
        fail "Kustomizations not reconciled:\n$BROKEN_KS"
    fi

    FLUX_SOURCE=$(flux get sources git flux-system --no-header 2>/dev/null | grep -v "True" || true)
    if [ -z "$FLUX_SOURCE" ]; then
        ok "Flux git source ready"
    else
        fail "Flux git source not ready: $FLUX_SOURCE"
    fi

    header "Phase 2: Storage"
    UNBOUND_PVC=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -v "Bound" || true)
    if [ -z "$UNBOUND_PVC" ]; then
        ok "All PVCs Bound"
    else
        fail "PVCs not Bound:\n$UNBOUND_PVC"
    fi

    LH_NODES=$(kubectl -n longhorn-system get nodes.longhorn.io --no-headers 2>/dev/null | wc -l)
    if [ "$LH_NODES" -ge 3 ]; then
        ok "Longhorn: $LH_NODES nodes registered"
    else
        warn "Longhorn: only $LH_NODES node(s) registered (expected 3)"
    fi

    header "Phase 2: Networking"
    if command -v cilium &>/dev/null; then
        if cilium status --wait=false 2>/dev/null | grep -q "OK"; then
            ok "Cilium status OK"
        else
            warn "Cilium status not fully OK — run: cilium status"
        fi
    else
        warn "cilium CLI not found — skipping Cilium check"
    fi

    CERT_NOT_READY=$(kubectl -n network get certificates --no-headers 2>/dev/null | grep -v " True " || true)
    if [ -z "$CERT_NOT_READY" ]; then
        ok "Certificates ready"
    else
        warn "Certificates not ready:\n$CERT_NOT_READY"
    fi

    header "Phase 2: Longhorn → Garage S3 backup"
    BACKUP_TARGET=$(kubectl -n longhorn-system get setting backup-target -o jsonpath='{.value}' 2>/dev/null || true)
    if echo "$BACKUP_TARGET" | grep -q "s3://"; then
        ok "Longhorn backup target configured: $BACKUP_TARGET"
    else
        fail "Longhorn backup target not configured (value: '$BACKUP_TARGET')"
    fi
}

# ---------------------------------------------------------------------------
# Phase 3 — Agents
# ---------------------------------------------------------------------------
verify_phase3() {
    header "Phase 3: OpenClaw service"

    if id openclaw &>/dev/null; then
        ok "openclaw user exists"
    else
        fail "openclaw user does not exist"
        return
    fi

    GW_STATUS=$(sudo -u openclaw \
        XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
        systemctl --user is-active openclaw-gateway 2>/dev/null || echo "inactive")
    if [ "$GW_STATUS" = "active" ]; then
        ok "openclaw-gateway systemd service active"
    else
        fail "openclaw-gateway service is: $GW_STATUS"
    fi

    header "Phase 3: OpenClaw health"
    if sudo -u openclaw openclaw status &>/dev/null 2>&1; then
        ok "openclaw status OK"
    else
        warn "openclaw status had issues — run: sudo -u openclaw openclaw status"
    fi

    if sudo -u openclaw openclaw doctor &>/dev/null 2>&1; then
        ok "openclaw doctor OK"
    else
        warn "openclaw doctor warnings — run: sudo -u openclaw openclaw doctor"
    fi

    header "Phase 3: Workspaces"
    WDIR="/home/openclaw/.openclaw"
    for ws in workspace workspace-blog workspace-design workspace-infra workspace-costs workspace-dashboard workspace-orchestrator workspace-renovate workspace-repo; do
        if [ -d "$WDIR/$ws" ]; then
            ok "workspace: $ws"
        else
            fail "workspace MISSING: $ws"
        fi
    done

    header "Phase 3: Dashboard"
    container_running "agents-dashboard"
    if [ -f "/srv/dashboard/data/agents.json" ]; then
        ok "agents.json exists"
    else
        warn "agents.json missing — agents haven't run yet or dashboard not initialized"
    fi
}

# ---------------------------------------------------------------------------
# Run selected phases
# ---------------------------------------------------------------------------
if [ "$RUN_PHASE" = "1" ] || [ "$RUN_PHASE" = "all" ]; then verify_phase1; fi
if [ "$RUN_PHASE" = "2" ] || [ "$RUN_PHASE" = "all" ]; then verify_phase2; fi
if [ "$RUN_PHASE" = "3" ] || [ "$RUN_PHASE" = "all" ]; then verify_phase3; fi

echo ""
echo "========================================"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${YELLOW}WARN: $WARN${NC}  ${RED}FAIL: $FAIL${NC}"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}DR phase $RUN_PHASE has FAILURES — investigate above${NC}"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo -e "${YELLOW}DR phase $RUN_PHASE passed with warnings${NC}"
    exit 0
else
    echo -e "${GREEN}DR phase $RUN_PHASE fully verified${NC}"
    exit 0
fi
