#!/usr/bin/env bash
# The API VIP (module 07; module 19 reuses it under kubeadm).
#
# keepalived speaks VRRP: the nodes elect one owner of ${API_VIP}, and the
# owner answers ARP for it. A health script lowers a node's priority when its
# local apiserver is not ready, so the VIP leaves a broken node.
#
# Talos does the same job differently: its VIP owner is whoever holds an etcd
# lease, so the VIP follows etcd, not the apiserver.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

peers_of() { local self=$1 n; for n in "${NODES[@]}"; do [[ $n == "$self" ]] || printf '    %s\n' "${NODE_IP[$n]}"; done; }
# 150, 140, 130… by position in NODES, so a node keeps its priority when only
# it is reinstalled (ONLY=…).
prio_of() { local self=$1 i; for i in "${!NODES[@]}"; do [[ ${NODES[$i]} == "$self" ]] && echo $((150 - 10 * i)); done; }

for n in "${TARGETS[@]}"; do
  prio=$(prio_of "$n")
  S=$(stage_dir keepalived "$n")
  mkdir -p "$S/etc/keepalived"

  cat >"$S/etc/keepalived/check-apiserver.sh" <<EOF
#!/bin/sh
# exit 0 = this node may hold the VIP. /readyz fails when the local apiserver
# cannot reach etcd too, so a node cut off from the quorum gives the VIP up.
exec curl -sfk --max-time 2 -o /dev/null https://127.0.0.1:${API_PORT}/readyz
EOF
  chmod 755 "$S/etc/keepalived/check-apiserver.sh"

  # @IFACE@ is filled in on the node: only the node knows its NIC's name.
  cat >"$S/etc/keepalived/keepalived.conf" <<EOF
global_defs {
  router_id ${n}
  enable_script_security
  script_user root
}

vrrp_script chk_apiserver {
  script "/etc/keepalived/check-apiserver.sh"
  interval 3
  timeout 2
  fall 2
  rise 2
  # Failing check: priority -50. ${n} at ${prio} drops below the next node.
  # If every check fails (bootstrap), the highest base priority still wins,
  # which is what lets the first apiserver come up behind the VIP.
  weight -50
}

vrrp_instance K8S_API {
  state BACKUP
  interface @IFACE@
  virtual_router_id 51
  priority ${prio}
  advert_int 1
  # Unicast instead of multicast: works on any bridge, VLAN or cloud network.
  unicast_src_ip ${NODE_IP[$n]}
  unicast_peer {
$(peers_of "$n")
  }
  virtual_ipaddress {
    ${API_VIP}/24
  }
  track_script {
    chk_apiserver
  }
}
EOF
  chmod 644 "$S/etc/keepalived/keepalived.conf"

  push_stage "$S" "$n"
  on "$n" 'sudo sed -i "s/@IFACE@/$(ip -o -4 route show to default | awk "{print \$5; exit}")/" /etc/keepalived/keepalived.conf && sudo systemctl enable --now keepalived >/dev/null 2>&1 && sudo systemctl restart keepalived'
  ok "$n: keepalived ($(on "$n" "grep -m1 interface /etc/keepalived/keepalived.conf | awk '{print \$2}'"))"
done

sleep 4
for n in "${NODES[@]}"; do
  if on "$n" "ip -4 -o addr show | grep -q ' ${API_VIP}/'"; then ok "VIP ${API_VIP} is on $n"; fi
done
