#!/usr/bin/env bash
# Verification for edge-fra, the public TLS edge in Frankfurt.
#
# Run from a workstation on the tailnet: half the checks have to come from
# outside the host (does the public address answer, and does it answer only for
# the one hostname it should), and half from inside it.
#
#   bash scripts/edge-verify.sh
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOSTS_FILE="$REPO_ROOT/vps/inventories/production/hosts"
VARS_FILE="$REPO_ROOT/vps/inventories/production/group_vars/edge_servers/vars.yml"

ok()    { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; WARN=$((WARN + 1)); }
fail()  { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }
header(){ echo -e "\n${CYAN}$1${NC}"; }

# Inventory is the single source of truth for how to reach the box. The public
# address is deliberately not in git — ask the host for it at run time.
EDGE_LINE=$(grep -E '^edge-fra ' "$HOSTS_FILE" || true)
if [ -z "$EDGE_LINE" ]; then
    echo "edge-fra not found in $HOSTS_FILE" >&2; exit 1
fi
TS_IP=$(sed -n 's/.*ansible_host=\([^ ]*\).*/\1/p' <<<"$EDGE_LINE")
SSH_USER=$(sed -n 's/.*ansible_user=\([^ ]*\).*/\1/p' <<<"$EDGE_LINE")
SSH_KEY=$(sed -n 's/.*ansible_ssh_private_key_file=\([^ ]*\).*/\1/p' <<<"$EDGE_LINE")
SSH_KEY="${SSH_KEY/#\~/$HOME}"
DOMAIN=$(sed -n 's/^jellyfin_domain: *"\(.*\)".*/\1/p' "$VARS_FILE")

edge() { ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" "${SSH_USER}@${TS_IP}" "$@"; }

header "Reachability"
if edge true 2>/dev/null; then
    ok "ssh over the tailnet ($TS_IP)"
else
    fail "cannot ssh to ${SSH_USER}@${TS_IP} with $SSH_KEY"; exit 1
fi

PUB_IP=$(edge "curl -s -m 8 https://api.ipify.org" || true)
if [[ "$PUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ok "public address $PUB_IP"
else
    fail "could not determine the public address"; exit 1
fi

header "Host firewall"
if edge "sudo iptables -S EDGE-INPUT" 2>/dev/null | grep -qE -- '--dports? 443 -j ACCEPT'; then
    ok "EDGE-INPUT accepts tcp/443"
else
    fail "EDGE-INPUT missing the public ACCEPT (run: sudo /usr/local/sbin/edge-firewall.sh)"
fi
if edge "sudo iptables -S INPUT" 2>/dev/null | grep -q -- '-A INPUT -j EDGE-INPUT'; then
    ok "INPUT enters EDGE-INPUT"
else
    fail "INPUT does not jump to EDGE-INPUT"
fi
if edge "systemctl is-enabled edge-firewall.service" 2>/dev/null | grep -q enabled; then
    ok "edge-firewall.service enabled, so the chain survives a reboot"
else
    fail "edge-firewall.service not enabled — the chain is gone after a reboot"
fi

header "Filtering"
# The five Romanian consumer ISPs announce ~615 prefixes between them; the
# role aborts a refresh below 100 rather than shrinking the set.
COUNT=$(edge "sudo ipset list geoblock_allow 2>/dev/null | grep -c '^[0-9]'" || echo 0)
if [ "${COUNT:-0}" -gt 500 ]; then
    ok "geoblock set holds $COUNT prefixes"
else
    fail "geoblock set holds ${COUNT:-0} prefixes (expected ~615)"
fi
if edge "sudo iptables -S EDGE-INPUT" 2>/dev/null | grep -q 'match-set geoblock_allow src -j DROP'; then
    ok "geoblock DROP is in EDGE-INPUT"
else
    fail "geoblock DROP missing — the port is open to the whole internet"
fi
if edge "sudo fail2ban-client status jellyfin-auth" &>/dev/null; then
    ok "fail2ban jail jellyfin-auth active"
else
    fail "fail2ban jail jellyfin-auth not running"
fi
for t in geoblock.timer egress-guard.timer; do
    if edge "systemctl is-active $t" 2>/dev/null | grep -q active; then
        ok "$t active"
    else
        fail "$t not active"
    fi
done

header "Proxy and backend"
# sudo: the login user is deliberately not in the docker group.
STATUS=$(edge "sudo docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' traefik" 2>/dev/null || true)
case "$STATUS" in
    running/healthy) ok "traefik container running and healthy" ;;
    running/*)       warn "traefik container running, health $STATUS" ;;
    *)               fail "traefik container not running (${STATUS:-absent})" ;;
esac
BACKEND_IP=$(sed -n 's/^jellyfin_backend_ip: *"\(.*\)".*/\1/p' "$VARS_FILE")
BACKEND_PORT=$(sed -n 's/^jellyfin_backend_port: *\(.*\)/\1/p' "$VARS_FILE")
if edge "curl -sf -m 8 http://${BACKEND_IP}:${BACKEND_PORT}/health" &>/dev/null; then
    ok "Jellyfin backend answers over the tailnet"
else
    fail "backend ${BACKEND_IP}:${BACKEND_PORT} unreachable (accept-routes off? pfSense subnet router down?)"
fi

header "From the internet"
# Everything below needs the OCI security list to allow 443. Until that rule is
# added the host is correctly built and correctly unreachable, which is a
# different thing from broken — say so rather than reporting six failures.
if ! nc -z -G 8 "$PUB_IP" 443 2>/dev/null; then
    warn "$PUB_IP:443 refuses connections — add the OCI ingress rule for TCP 443"
    echo -e "\n${GREEN}${PASS} passed${NC}, ${YELLOW}$((WARN))${NC} warnings, ${RED}${FAIL} failed${NC} (external checks skipped)"
    [ "$FAIL" -eq 0 ]
    exit
fi

DNS_IP=$(dig +short "$DOMAIN" @1.1.1.1 | tail -1)
if [ "$DNS_IP" = "$PUB_IP" ]; then
    ok "$DOMAIN resolves to $PUB_IP, grey cloud"
elif [ -z "$DNS_IP" ]; then
    fail "$DOMAIN does not resolve"
else
    warn "$DOMAIN resolves to $DNS_IP, not $PUB_IP — still pointing at the old origin, or proxied"
fi

CODE=$(curl -sk -o /dev/null -w '%{http_code}' -m 10 "https://${DOMAIN}/" || true)
if [[ "$CODE" =~ ^(200|302)$ ]]; then
    ok "https://${DOMAIN} answers $CODE"
else
    fail "https://${DOMAIN} answers $CODE"
fi

ISSUER=$(echo | openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null \
         | openssl x509 -noout -issuer 2>/dev/null || true)
if grep -qi "let's encrypt" <<<"$ISSUER"; then
    ok "certificate issued by Let's Encrypt"
else
    fail "unexpected certificate issuer: ${ISSUER:-none}"
fi

# The check that matters most. A router bound to this listener for any other
# hostname would answer here; none should exist on this host at all.
for host in sso.merox.dev rmt.merox.dev traefik.cloud.merox.dev; do
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' -m 10 -H "Host: $host" "https://${PUB_IP}/" || true)
    if [ "$CODE" = "404" ]; then
        ok "$host is not served here ($CODE)"
    else
        fail "$host answered $CODE on the public address — a private router is bound to this listener"
    fi
done

echo -e "\n${GREEN}${PASS} passed${NC}, ${YELLOW}${WARN} warnings${NC}, ${RED}${FAIL} failed${NC}"
[ "$FAIL" -eq 0 ]
