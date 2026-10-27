#!/usr/bin/env bash
# Module 01: turn lab-gw into the lab's router — IP forwarding, a firewall,
# NAT out. BGP (FRR) comes later, in module 10 (setup-frr.sh): first you see
# the cluster without it, then you see what it adds.
#
#   sudo ./setup-router.sh
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../env.sh
source "${HERE}/../../env.sh"

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

# Find the interfaces by the address cloud-init gave them, not by name:
# ens18/ens19 today, something else on another hypervisor.
iface_with() { ip -o -4 addr show | awk -v ip="$1" '{split($4, a, "/"); if (a[1] == ip) print $2}'; }
WAN_IF=$(iface_with "$ROUTER_WAN_IP")
LAN_IF=$(iface_with "$LAB_GATEWAY")
if [[ -z $WAN_IF || -z $LAN_IF ]]; then
  echo "cannot find WAN ($ROUTER_WAN_IP) or LAN ($LAB_GATEWAY) on this host:" >&2
  ip -br -4 addr >&2
  exit 1
fi
echo "→ WAN=$WAN_IF  LAN=$LAN_IF"

echo "→ forwarding on"
cat > /etc/sysctl.d/90-lab-router.conf <<'EOF'
# A Linux box drops packets not addressed to itself unless told to route.
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

echo "→ packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables tcpdump dnsutils traceroute jq curl git >/dev/null

echo "→ firewall + NAT"
sed -e "s|@WAN_IF@|${WAN_IF}|" -e "s|@LAN_IF@|${LAN_IF}|" -e "s|@HOME_LAN@|${HOME_LAN}|" \
  "${HERE}/nftables.conf" > /etc/nftables.conf
nft -c -f /etc/nftables.conf          # syntax check before anything changes
systemctl enable --now nftables >/dev/null
nft -f /etc/nftables.conf

echo "→ /etc/hosts"
sed -i '/# k8s-lab begin/,/# k8s-lab end/d' /etc/hosts
{
  echo "# k8s-lab begin"
  echo "${API_VIP} api.${LAB_DOMAIN}"
  for n in "${NODES[@]}"; do echo "${NODE_IP[$n]} ${n}"; done
  echo "# k8s-lab end"
} >> /etc/hosts
mkdir -p /etc/cloud/cloud.cfg.d
echo "manage_etc_hosts: false" > /etc/cloud/cloud.cfg.d/99-k8s-lab.cfg

echo
echo "✓ lab-gw routes ${LAB_CIDR} ⇄ ${HOME_LAN}."
echo "  Check from here:   ping -c1 ${NODE_IP[k8s-1]} && ping -c1 1.1.1.1"
echo "  From a node:       ssh ${SSH_USER}@${NODE_IP[k8s-1]} 'curl -sI https://dl.k8s.io | head -1'"
echo "  On your PC (once): route -p add 10.10.0.0 mask 255.255.0.0 ${ROUTER_WAN_IP}"
