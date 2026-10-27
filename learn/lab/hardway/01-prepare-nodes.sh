#!/usr/bin/env bash
# Module 06, step 01 — the OS underneath Kubernetes. Talos ships all of this
# baked in; on Ubuntu it is yours to do, and each line is a reason a kubelet
# would otherwise fail or a pod would misbehave.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

HOSTS="# k8s-lab begin"$'\n'"${API_VIP} api.${LAB_DOMAIN}"
for n in "${NODES[@]}"; do HOSTS+=$'\n'"${NODE_IP[$n]} ${n}"; done
HOSTS+=$'\n'"# k8s-lab end"

for n in "${NODES[@]}"; do
  log "$n (${NODE_IP[$n]})"
  # ssh joins its arguments into one string for the remote shell, so the
  # arguments are quoted here (%q) or the '#' in HOSTS would start a comment.
  on "$n" "sudo bash -s -- $(printf '%q ' "$n" "$HOSTS")" <<'REMOTE'
set -Eeuo pipefail
NODE=$1 HOSTS=$2

# 1. Swap off. The kubelet's memory accounting (requests, evictions, QoS)
#    assumes RAM is RAM. It refuses to start with swap unless told otherwise.
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

# 2. Kernel modules. overlay: containerd's snapshotter. br_netfilter: bridged
#    traffic visible to netfilter (needed by kube-proxy; Cilium does not, but
#    it is the standard baseline). iscsi_tcp: Longhorn attaches volumes over
#    iSCSI — the same reason prod's Talos image carries iscsi-tools.
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
iscsi_tcp
tcp_bbr
EOF
# The cloud image's kernel is a trimmed flavour; a module it lacks ships in
# linux-modules-extra for the same kernel.
for m in overlay br_netfilter iscsi_tcp tcp_bbr; do
  if ! modprobe "$m" 2>/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "linux-modules-extra-$(uname -r)" >/dev/null
    modprobe "$m"
  fi
done

# 3. sysctls. The first block is Kubernetes' baseline; the second is copied
#    from prod's talos/patches/global/machine-sysctls.yaml, reasons included.
cat > /etc/sysctl.d/90-k8s.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
EOF
sysctl --system >/dev/null

# 4. Packages. conntrack/socat: kubelet port-forward and service debugging.
#    open-iscsi + nfs-common: Longhorn and NFS volumes. keepalived: the API
#    VIP (module 07).
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  conntrack socat ipset jq curl ca-certificates open-iscsi nfs-common keepalived >/dev/null
systemctl enable --now iscsid >/dev/null 2>&1
# multipathd claims every block device it sees, Longhorn's included, and the
# volume then fails to mount. Longhorn's docs say: disable it or blacklist.
systemctl disable --now multipathd.service multipathd.socket >/dev/null 2>&1 || true
# keepalived starts with an empty config otherwise; module 07 starts it.
systemctl disable --now keepalived >/dev/null 2>&1 || true

# 5. Names. The node name is the hostname, and it must equal the CN in this
#    node's kubelet certificate (system:node:<name>) or the Node authorizer
#    refuses every request the kubelet makes.
hostnamectl set-hostname "$NODE"
sed -i '/# k8s-lab begin/,/# k8s-lab end/d' /etc/hosts
printf '%s\n' "$HOSTS" >> /etc/hosts
mkdir -p /etc/cloud/cloud.cfg.d
echo "manage_etc_hosts: false" > /etc/cloud/cloud.cfg.d/99-k8s-lab.cfg

# 6. Time. TLS and etcd both break on clock skew; check it is synchronized.
timedatectl show -p NTPSynchronized --value | grep -q yes || echo "  ! clock not synchronized yet on $NODE"
echo "  done: $(uname -r), cgroup $(stat -fc %T /sys/fs/cgroup)"
REMOTE
done

ok "nodes prepared. Next: ./02-pki.sh"
