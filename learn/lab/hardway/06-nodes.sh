#!/usr/bin/env bash
# Module 08, step 06 — every node also runs workloads (as in prod, where
# allowSchedulingOnControlPlanes is on): runc, containerd, CNI plugins,
# crictl, kubelet. The nodes register but stay NotReady until a CNI exists.
#
#   RUNTIME_ONLY=1 ./06-nodes.sh    containerd stack only (module 19, kubeadm)
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl
require_file "$DL/kubelet" "$DL/runc" "$PKI/ca.crt"
RUNTIME_ONLY=${RUNTIME_ONLY:-0}

CTR_TGZ="$DL/containerd-${CONTAINERD_VERSION#v}-linux-amd64.tar.gz"
CNI_TGZ="$DL/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz"
CRICTL_TGZ="$DL/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
require_file "$CTR_TGZ" "$CNI_TGZ" "$CRICTL_TGZ"

for n in "${TARGETS[@]}"; do
  ip=${NODE_IP[$n]}
  S=$(stage_dir 06-nodes "$n")
  mkdir -p "$S/usr/local/bin" "$S/usr/local/sbin" "$S/opt/cni/bin" "$S/etc/cni/net.d" \
    "$S/etc/containerd" "$S/etc/systemd/system" "$S/etc/kubernetes/manifests" "$S/etc/kubernetes/pki" \
    "$S/var/lib/kubelet/pki"

  # --- the runtime: runc does the namespaces+cgroups, containerd manages
  #     images, snapshots and the runc lifecycle, and serves the CRI.
  tar -xzf "$CTR_TGZ" -C "$S/usr/local" bin/        # bin/containerd, bin/containerd-shim-runc-v2, bin/ctr
  install -m 755 "$DL/runc" "$S/usr/local/sbin/runc"
  tar -xzf "$CNI_TGZ" -C "$S/opt/cni/bin"
  tar -xzf "$CRICTL_TGZ" -C "$S/usr/local/bin" crictl
  cat >"$S/etc/crictl.yaml" <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

  cat >"$S/etc/systemd/system/containerd.service" <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
# Delegate: containerd (and the shims) create cgroups below their own.
Delegate=yes
# KillMode=process: restarting containerd must not kill the containers.
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

  if [[ $RUNTIME_ONLY != 1 ]]; then
    # --- the kubelet: the node agent. It watches the API for pods bound to
    #     this node and makes containerd run them.
    install -m 755 "$DL/kubelet" "$DL/kubectl" "$S/usr/local/bin/"
    install -m 644 "$PKI/ca.crt" "$S/etc/kubernetes/pki/ca.crt"
    install -m 644 "$PKI/kubelet-${n}-serving.crt" "$S/var/lib/kubelet/pki/kubelet.crt"
    install -m 600 "$PKI/kubelet-${n}-serving.key" "$S/var/lib/kubelet/pki/kubelet.key"
    install -m 600 "$KC/kubelet-${n}.kubeconfig" "$S/var/lib/kubelet/kubeconfig"

    cat >"$S/var/lib/kubelet/config.yaml" <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Who may call this kubelet's API on :10250: certs from the cluster CA,
# then the apiserver decides (Webhook) — never anonymous.
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
# Must match containerd's (SystemdCgroup = true below). Two cgroup managers
# on one host fight, and the node goes unstable under memory pressure.
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
clusterDomain: ${CLUSTER_DOMAIN}
clusterDNS:
  - ${CLUSTER_DNS_IP}
# Ubuntu's /etc/resolv.conf points at systemd-resolved on 127.0.0.53. Hand that
# to a pod and CoreDNS forwards to itself — its 'loop' plugin then kills it.
resolvConf: /run/systemd/resolve/resolv.conf
staticPodPath: /etc/kubernetes/manifests
tlsCertFile: /var/lib/kubelet/pki/kubelet.crt
tlsPrivateKeyFile: /var/lib/kubelet/pki/kubelet.key
# Certificates were made by hand in 02-pki.sh; nothing rotates them.
rotateCertificates: false
serverTLSBootstrap: false
# Copied from prod, talos/patches/global/machine-kubelet.yaml — read the
# reasons there.
serializeImagePulls: false
maxParallelImagePulls: 3
imageMaximumGCAge: 168h
shutdownGracePeriod: 90s
shutdownGracePeriodCriticalPods: 60s
EOF

    cat >"$S/etc/systemd/system/kubelet.service" <<EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/config.yaml \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --node-ip=${ip} \\
  --v=2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  fi

  log "$n: push $(du -sh "$S" | cut -f1)"
  push_stage "$S" "$n"

  on "$n" sudo bash -s <<'REMOTE'
set -Eeuo pipefail
# containerd's defaults, then one change: runc uses systemd cgroups.
if [[ ! -f /etc/containerd/config.toml ]]; then
  containerd config default > /etc/containerd/config.toml
fi
if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
elif ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  sed -i "/\[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options\]/a\            SystemdCgroup = true" /etc/containerd/config.toml
fi
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || { echo "could not set SystemdCgroup" >&2; exit 1; }
systemctl daemon-reload
systemctl enable --now containerd >/dev/null 2>&1
systemctl restart containerd
if [[ -f /etc/systemd/system/kubelet.service ]]; then
  systemctl enable --now kubelet >/dev/null 2>&1
  systemctl restart kubelet
fi
REMOTE
  ok "$n: containerd $(on "$n" "/usr/local/bin/containerd --version | awk '{print \$3}'")"
done

[[ $RUNTIME_ONLY == 1 ]] && { ok "runtime installed (RUNTIME_ONLY)"; exit 0; }

for n in "${TARGETS[@]}"; do wait_for 60 "$n registered" kubectl get node "$n"; done

# The kubelet may not label itself node-role.kubernetes.io/* (NodeRestriction
# forbids it — otherwise a compromised node could promote itself). An admin does.
for n in "${TARGETS[@]}"; do kubectl label node "$n" node-role.kubernetes.io/control-plane= --overwrite >/dev/null; done

kubectl get nodes -o wide
ok "nodes registered — NotReady is expected: no CNI yet. Next: ./07-addons.sh"
