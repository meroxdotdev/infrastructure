# shellcheck shell=bash
# The lab's single source of truth for names and addresses. Every script in
# learn/lab sources this file; change a value here, never in a script.
#
# Plan (docs/01-laborator.md has the diagram):
#
#   home LAN 10.57.57.0/24 ── lab-gw (router + jumpbox) ── lab 10.10.0.0/24
#                             WAN: ROUTER_WAN_IP            LAN: 10.10.0.1
#
#   10.10.0.10       API VIP (keepalived)        ≈ prod 10.57.57.88 (Talos VIP)
#   10.10.0.11-13    k8s-1..3, all control plane ≈ prod kubernetes-1..3
#   10.10.100.0/24   LoadBalancer IPs, via BGP   ≈ prod LB_IP_* via L2 announcements
#   10.244.0.0/16    pods                        ≈ prod 10.42.0.0/16
#   10.96.0.0/12     services                    ≈ prod 10.43.0.0/16

# --- the home side: change these two to match your LAN -----------------------
ROUTER_WAN_IP="10.57.57.90"        # a free address on the home LAN, outside DHCP
HOME_LAN="10.57.57.0/24"
HOME_GATEWAY="10.57.57.1"          # pfSense

# --- the lab side ------------------------------------------------------------
LAB_DOMAIN="lab.merox.dev"
CLUSTER_NAME="lab"
LAB_CIDR="10.10.0.0/24"
LAB_GATEWAY="10.10.0.1"
API_VIP="10.10.0.10"
API_PORT="6443"

NODES=(k8s-1 k8s-2 k8s-3)
declare -A NODE_IP=(
  [k8s-1]="10.10.0.11"
  [k8s-2]="10.10.0.12"
  [k8s-3]="10.10.0.13"
)

POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
KUBERNETES_SVC_IP="10.96.0.1"      # first IP of SERVICE_CIDR: the `kubernetes` Service
CLUSTER_DNS_IP="10.96.0.10"        # CoreDNS Service; kubelet writes it into every pod
CLUSTER_DOMAIN="cluster.local"

LB_POOL="10.10.100.0/24"
LB_IP_GATEWAY="10.10.100.10"       # Cilium Gateway `internal`
LB_IP_DNS="10.10.100.53"           # k8s-gateway

ROUTER_ASN="65000"                 # lab-gw (FRR) — plays the top-of-rack switch
CLUSTER_ASN="65001"                # every node (Cilium BGP control plane)

SSH_USER="ubuntu"

# Where the jumpbox keeps downloads, PKI and rendered configs.
WORKDIR="${WORKDIR:-$HOME/hardway}"
# learn/lab, wherever this checkout lives.
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=versions.env
source "${LAB_DIR}/versions.env"

all_node_ips() { local n; for n in "${NODES[@]}"; do printf '%s ' "${NODE_IP[$n]}"; done; }
