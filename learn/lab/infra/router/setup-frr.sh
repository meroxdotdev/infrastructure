#!/usr/bin/env bash
# Module 10: lab-gw speaks BGP. Run it before applying the Cilium BGP
# resources, or after — the sessions come up whenever both sides exist.
#
#   sudo ./setup-frr.sh
#   sudo vtysh -c 'show bgp summary'
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../env.sh
source "${HERE}/../../env.sh"

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq frr >/dev/null

# bgpd is off by default; zebra (the part that writes kernel routes) is always on.
sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons

# One "neighbor" pair per node. Joined with a literal \n, which awk -v turns
# into a newline (a raw newline inside -v is not portable across awks).
NEIGHBORS=""
for n in "${NODES[@]}"; do
  NEIGHBORS+="${NEIGHBORS:+\\n} neighbor ${NODE_IP[$n]} peer-group K8S\\n neighbor ${NODE_IP[$n]} description ${n}"
done

awk -v nb="${NEIGHBORS}" '{ if ($0 == "@NEIGHBORS@") print nb; else print }' "${HERE}/frr.conf" |
  sed -e "s|@ROUTER_ASN@|${ROUTER_ASN}|" -e "s|@CLUSTER_ASN@|${CLUSTER_ASN}|" \
      -e "s|@LAB_GATEWAY@|${LAB_GATEWAY}|" -e "s|@LB_POOL@|${LB_POOL}|" -e "s|@POD_CIDR@|${POD_CIDR}|" \
  > /etc/frr/frr.conf
chown frr:frr /etc/frr/frr.conf
chmod 640 /etc/frr/frr.conf

systemctl restart frr
sleep 2
vtysh -c 'show bgp summary' || true
echo
echo "✓ FRR up as AS ${ROUTER_ASN}. Peers stay 'Active' until Cilium's BGP resources exist (module 10)."
