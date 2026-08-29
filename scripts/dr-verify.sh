#!/usr/bin/env bash
# DR verification — run after each phase to confirm it succeeded
# Usage:
#   bash scripts/dr-verify.sh --phase 1   (VPS — run on the VPS)
#   bash scripts/dr-verify.sh --phase 2   (K8s — run from local machine with kubectl)
#   bash scripts/dr-verify.sh --phase all (runs all — assumes you're on the VPS)
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0

# Resolve paths regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VARS_FILE="$REPO_ROOT/vps/inventories/production/group_vars/vps_servers/vars.yml"

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

# Check HTTP on container's internal IP (for services not exposed on host)
container_http_ok() {
    local label="$1" container="$2" port="$3" path="${4:-/}"
    local ip
    ip=$(docker inspect "$container" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1)
    if [ -z "$ip" ]; then
        fail "$label — cannot get IP for container $container"
        return
    fi
    if curl -sf --max-time 5 "http://${ip}:${port}${path}" &>/dev/null; then
        ok "$label responds"
    else
        fail "$label not responding (http://${ip}:${port}${path})"
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
    *"--phase all"*) RUN_PHASE=all ;;
    *) echo "Usage: $0 --phase 1|2|all"; exit 1 ;;
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
    container_running "homepage-public"
    container_running "homelab-stats-server"
    container_running "portainer"
    container_running "pihole"
    container_running "unbound"
    container_running "traefik"

    # Cloudflare Tunnel (cloudflared_setup role — own compose at /srv/docker/cloudflared/)
    container_running "cloudflared"

    header "Phase 1: VPS Containers (sub-composes)"
    container_running "authentik-server"
    container_running "authentik-worker"
    container_running "authentik-postgresql"
    container_running "guacamole"

    header "Phase 1: Service health"

    # Traefik: api.insecure not set so port 8080 is not active — verify via process check
    if docker exec traefik pgrep traefik &>/dev/null; then
        ok "Traefik process running"
    else
        fail "Traefik process not found in container"
    fi

    # Pi-hole DNS — docker exec with || true to avoid non-zero exit from bash readonly var warning
    PIHOLE_STATUS=$(docker exec pihole pihole status 2>/dev/null || true)
    if echo "$PIHOLE_STATUS" | grep -q "FTL is listening"; then
        ok "Pi-hole DNS resolves"
    else
        fail "Pi-hole DNS not responding (docker exec pihole pihole status)"
    fi

    # Homepage (exposed on host 127.0.0.1:3000)
    http_ok "Homepage" "http://localhost:3000"

    # Joplin: /api/ping rejects requests from non-APP_BASE_URL origins — check port is open instead
    JOPLIN_IP=$(docker inspect joplin-server --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
    if [ -n "$JOPLIN_IP" ] && nc -z -w3 "$JOPLIN_IP" 22300 2>/dev/null; then
        ok "Joplin API port open"
    else
        fail "Joplin API port not reachable (${JOPLIN_IP:-no IP}:22300)"
    fi

    # Authentik: check metrics port 9300 (always up when server is healthy)
    container_http_ok "Authentik" "authentik-server" 9300 "/metrics"

    # Portainer binds to the Tailscale IP only (100.72.22.38:9000/9443, see
    # docker-compose.yml), not localhost — check via the container's internal
    # IP instead, same as the Authentik check above.
    container_http_ok "Portainer" "portainer" 9000 "/api/system/status"

    header "Phase 1: System"
    DISK=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$DISK" -lt 80 ]; then
        ok "Disk usage: ${DISK}%"
    else
        warn "Disk usage HIGH: ${DISK}%"
    fi

    if tailscale status &>/dev/null 2>&1; then
        TS_IP=$(tailscale ip -4 2>/dev/null || true)
        ok "Tailscale connected ($TS_IP)"
        TS_EXPECTED=$(grep "^tailscale_expected_ip:" "$VARS_FILE" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
        if [ -n "$TS_EXPECTED" ] && [ "$TS_IP" != "$TS_EXPECTED" ]; then
            warn "  IP changed from $TS_EXPECTED to $TS_IP — update tailscale_expected_ip in vars.yml"
        fi
    else
        fail "Tailscale not connected (tailscale status)"
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

    header "Phase 2: Storage — PVCs"
    UNBOUND_PVC=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -v "Bound" || true)
    if [ -z "$UNBOUND_PVC" ]; then
        ok "All PVCs Bound"
    else
        fail "PVCs not Bound:\n$UNBOUND_PVC"
    fi

    header "Phase 2: Storage — Longhorn nodes"
    LH_NODES=$(kubectl -n longhorn-system get nodes.longhorn.io --no-headers 2>/dev/null | wc -l)
    K8S_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [ "$LH_NODES" -ge "$K8S_NODES" ]; then
        ok "Longhorn: $LH_NODES nodes registered"
    else
        warn "Longhorn: only $LH_NODES/$K8S_NODES node(s) registered"
    fi

    header "Phase 2: Storage — CSI driver registration"
    # CRITICAL: driver.longhorn.io must be registered on all nodes.
    # If missing, NO volume can attach. Caused by duplicate default/longhorn install.
    MISSING_DRIVER=0
    for node in $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
        HAS_DRIVER=$(kubectl get csinode "$node" -o jsonpath='{.spec.drivers[*].name}' 2>/dev/null | grep -c "driver.longhorn.io" || true)
        if [ "$HAS_DRIVER" -ge 1 ]; then
            ok "CSI driver registered on $node"
        else
            fail "driver.longhorn.io NOT registered on $node — run: task longhorn:restore (fix-duplicate-longhorn step)"
            MISSING_DRIVER=$((MISSING_DRIVER + 1))
        fi
    done

    # A real duplicate install (2026-06-04, found 2026-08-26) sat undetected
    # for 82 days because this check only looked for a Flux HelmRelease CRD -
    # the actual leftover was a raw `helm install` (a plain Secret,
    # sh.helm.release.v1.longhorn.v1) plus 35 orphaned Volume CRs, 5 Engine
    # CRs, an EngineImage, 4 Services, 3 ConfigMaps, 2 Secrets and an
    # OCIRepository, none of which a HelmRelease-only check would ever see.
    # Check every object kind Longhorn actually creates, not just one of them.
    header "Phase 2: Storage — Duplicate Longhorn check"
    DUP_FOUND=0
    if kubectl get helmrelease longhorn -n default &>/dev/null; then
        fail "Duplicate default/longhorn HelmRelease found — will break ALL volume attachments!"
        fail "Fix: kubectl delete helmrelease longhorn -n default && helm uninstall longhorn -n default"
        DUP_FOUND=1
    fi
    if kubectl get secret -n default --no-headers 2>/dev/null | grep -q '^sh\.helm\.release\.v1\.longhorn\.'; then
        fail "Raw Helm release record for 'longhorn' found in default (sh.helm.release.v1.longhorn.*) — a plain 'helm install' bypassing Flux, not caught by the HelmRelease check above"
        DUP_FOUND=1
    fi
    for kind in volumes.longhorn.io engines.longhorn.io replicas.longhorn.io engineimages.longhorn.io; do
        COUNT=$(kubectl get "$kind" -n default --no-headers 2>/dev/null | wc -l)
        if [ "$COUNT" -gt 0 ]; then
            fail "$COUNT $kind object(s) found in default namespace — should only exist in longhorn-system"
            DUP_FOUND=1
        fi
    done
    if kubectl get ocirepository longhorn -n default &>/dev/null; then
        fail "OCIRepository 'longhorn' found in default namespace — should only exist in longhorn-system"
        DUP_FOUND=1
    fi
    if [ "$DUP_FOUND" -eq 0 ]; then
        ok "No duplicate Longhorn install (HelmRelease, raw Helm release, Volume/Engine/Replica/EngineImage CRs, or OCIRepository) in default"
    fi

    header "Phase 2: Storage — Restore volumes"
    DETACHED=$(kubectl get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null \
        | grep "restored" | grep -v "attached" | grep -v "detached" || true)
    ATTACHED=$(kubectl get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null \
        | grep "restored" | grep "attached" | wc -l || echo 0)
    TOTAL=$(kubectl get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null \
        | grep -c "restored" || echo 0)
    # Expected count is derived from restore-all-volumes, never hardcoded —
    # a literal here silently went stale once and cost the Immich library.
    EXPECTED=$(grep -c "^      - task: restore-volume" \
        "$REPO_ROOT/.taskfiles/longhorn/Taskfile.yaml" 2>/dev/null || echo 0)
    if [ "$EXPECTED" -eq 0 ]; then
        warn "Could not read restore-all-volumes; skipping volume-count check"
    elif [ "$TOTAL" -ge "$EXPECTED" ]; then
        ok "Restore volumes exist: $TOTAL total, $ATTACHED attached"
    else
        fail "Only $TOTAL restore volumes found (restore-all-volumes defines $EXPECTED) — run: task longhorn:restore"
    fi

    header "Phase 2: Storage — Longhorn BackupTarget"
    # In Longhorn 1.11.2, BackupTarget is a CRD (not a Setting)
    BACKUP_URL=$(kubectl get backuptarget default -n longhorn-system \
        -o jsonpath='{.spec.backupTargetURL}' 2>/dev/null || true)
    if echo "$BACKUP_URL" | grep -q "s3://"; then
        ok "BackupTarget CRD configured: $BACKUP_URL"
    else
        # Fallback: check legacy Setting (Longhorn < 1.11.2)
        BACKUP_SETTING=$(kubectl -n longhorn-system get setting backup-target \
            -o jsonpath='{.value}' 2>/dev/null || true)
        if echo "$BACKUP_SETTING" | grep -q "s3://"; then
            ok "Backup target (Setting) configured: $BACKUP_SETTING"
        else
            fail "Longhorn backup target not configured — run: task longhorn:restore (patch-backup-target step)"
        fi
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
}

# ---------------------------------------------------------------------------
# Run selected phases
# ---------------------------------------------------------------------------
if [ "$RUN_PHASE" = "1" ] || [ "$RUN_PHASE" = "all" ]; then verify_phase1; fi
if [ "$RUN_PHASE" = "2" ] || [ "$RUN_PHASE" = "all" ]; then verify_phase2; fi

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
