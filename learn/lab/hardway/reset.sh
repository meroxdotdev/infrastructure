#!/usr/bin/env bash
# Wipe Kubernetes, etcd and containerd state from every node, keep the OS
# preparation (01) and the jumpbox's PKI. For repeating the hard way, or for
# module 19's kubeadm rebuild. Destroys every workload and every volume.
#
#   ./reset.sh            asks first
#   ./reset.sh --yes
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

if [[ ${1:-} != --yes ]]; then
  read -r -p "This destroys the cluster on ${NODES[*]}. Type 'reset' to continue: " a
  [[ $a == reset ]] || die "aborted"
fi

for n in "${NODES[@]}"; do
  log "$n"
  on "$n" sudo bash -s <<'REMOTE'
set -u
command -v kubeadm >/dev/null && kubeadm reset -f >/dev/null 2>&1
for s in kubelet keepalived kube-scheduler kube-controller-manager kube-apiserver etcd containerd; do
  systemctl disable --now "$s" >/dev/null 2>&1
done
# Stop anything still running in a container cgroup.
pkill -9 -f containerd-shim >/dev/null 2>&1
rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/etcd /var/log/kubernetes \
       /etc/cni/net.d /var/lib/cni /opt/cni /run/cilium /var/run/cilium \
       /var/lib/containerd /etc/containerd /etc/keepalived/keepalived.conf /etc/keepalived/check-apiserver.sh
rm -f /etc/systemd/system/{kubelet,kube-apiserver,kube-controller-manager,kube-scheduler,etcd,containerd}.service
systemctl daemon-reload
echo "  wiped"
REMOTE
done

warn "Cilium leaves eBPF programs, routes and interfaces in the kernel. Reboot the nodes:"
echo "  for ip in $(all_node_ips); do ssh ${SSH_USER}@\$ip sudo reboot; done"
