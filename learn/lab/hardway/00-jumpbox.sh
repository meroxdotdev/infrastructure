#!/usr/bin/env bash
# Module 06, step 00 — on lab-gw. Client tools for you, and every server
# binary downloaded once and checksum-verified. Nothing touches the nodes.
#
# Why verify: a binary from the internet runs as root on every node. The
# .sha256 next to it on the same server does not prove who built it (that is
# what signatures are for, module 16), but it does prove you got the file the
# project published, uncorrupted.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

ARCH=amd64
BIN="$HOME/.local/bin"
mkdir -p "$DL" "$BIN"

fetch() { # fetch <url> <dest>
  [[ -s $2 ]] && return 0
  log "download $(basename "$2")"
  curl -fsSL --retry 3 -o "$2.part" "$1"
  mv "$2.part" "$2"
}

# verify <file> <url-of-checksum-file> [name-inside-that-file]
verify() {
  local file=$1 sums=$2 name=${3:-} expected actual
  if ! expected=$(curl -fsSL --retry 3 "$sums"); then
    warn "no checksum at $sums — $(basename "$file") NOT verified"
    return 0
  fi
  if [[ -n $name ]]; then expected=$(awk -v n="$name" '$2 == n || $2 == "*"n {print $1}' <<<"$expected"); fi
  expected=${expected%% *}
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  [[ $expected == "$actual" ]] || die "checksum mismatch for $(basename "$file"): expected $expected, got $actual"
}

# --- Kubernetes: one .sha256 per binary -------------------------------------
for b in kube-apiserver kube-controller-manager kube-scheduler kubelet kubectl; do
  url="https://dl.k8s.io/${KUBERNETES_VERSION}/bin/linux/${ARCH}/${b}"
  fetch "$url" "$DL/$b"
  verify "$DL/$b" "$url.sha256"
  chmod +x "$DL/$b"
done
ok "kubernetes ${KUBERNETES_VERSION}"

# --- etcd --------------------------------------------------------------------
t="etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"
fetch "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/${t}" "$DL/$t"
verify "$DL/$t" "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/SHA256SUMS" "$t"
tar -xzf "$DL/$t" -C "$DL" --strip-components=1 "${t%.tar.gz}/etcd" "${t%.tar.gz}/etcdctl" "${t%.tar.gz}/etcdutl"
ok "etcd ${ETCD_VERSION}"

# --- containerd, runc, CNI plugins, crictl ------------------------------------
v=${CONTAINERD_VERSION#v}
t="containerd-${v}-linux-${ARCH}.tar.gz"
fetch "https://github.com/containerd/containerd/releases/download/${CONTAINERD_VERSION}/${t}" "$DL/$t"
verify "$DL/$t" "https://github.com/containerd/containerd/releases/download/${CONTAINERD_VERSION}/${t}.sha256sum"
ok "containerd ${CONTAINERD_VERSION}"

fetch "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}" "$DL/runc"
verify "$DL/runc" "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.sha256sum" "runc.${ARCH}"
chmod +x "$DL/runc"
ok "runc ${RUNC_VERSION}"

t="cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz"
fetch "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/${t}" "$DL/$t"
verify "$DL/$t" "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/${t}.sha256"
ok "cni-plugins ${CNI_PLUGINS_VERSION}"

t="crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
fetch "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${t}" "$DL/$t"
verify "$DL/$t" "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${t}.sha256"
ok "crictl ${CRICTL_VERSION}"

# --- tools for you, on the jumpbox ---------------------------------------------
install -m 755 "$DL/kubectl" "$DL/etcdctl" "$DL/etcdutl" "$BIN/"

if ! "$BIN/helm" version --short 2>/dev/null | grep -q "${HELM_VERSION}"; then
  t="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  fetch "https://get.helm.sh/${t}" "$DL/$t"
  verify "$DL/$t" "https://get.helm.sh/${t}.sha256sum"
  tar -xzf "$DL/$t" -C "$BIN" --strip-components=1 "linux-${ARCH}/helm"
fi
ok "helm ${HELM_VERSION}"

v=${HELMFILE_VERSION#v}
t="helmfile_${v}_linux_${ARCH}.tar.gz"
fetch "https://github.com/helmfile/helmfile/releases/download/${HELMFILE_VERSION}/${t}" "$DL/$t"
verify "$DL/$t" "https://github.com/helmfile/helmfile/releases/download/${HELMFILE_VERSION}/helmfile_${v}_checksums.txt" "$t"
tar -xzf "$DL/$t" -C "$BIN" helmfile
ok "helmfile ${HELMFILE_VERSION}"

t="cilium-linux-${ARCH}.tar.gz"
fetch "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${t}" "$DL/cilium-cli-${CILIUM_CLI_VERSION}.tar.gz"
verify "$DL/cilium-cli-${CILIUM_CLI_VERSION}.tar.gz" "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${t}.sha256sum"
tar -xzf "$DL/cilium-cli-${CILIUM_CLI_VERSION}.tar.gz" -C "$BIN" cilium
ok "cilium-cli ${CILIUM_CLI_VERSION}"

# mikefarah's yq — the one prod's Taskfiles use. Ubuntu's `yq` package is a
# different program with a different syntax. Its release checksums come in a
# multi-hash format, so this one is pinned but not verified.
fetch "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" "$DL/yq-${YQ_VERSION}"
install -m 755 "$DL/yq-${YQ_VERSION}" "$BIN/yq"
ok "yq ${YQ_VERSION}"

# helm diff is what makes `helmfile sync/apply` show you a diff first.
"$BIN/helm" plugin list 2>/dev/null | grep -q '^diff' || "$BIN/helm" plugin install https://github.com/databus23/helm-diff >/dev/null 2>&1 || warn "helm-diff not installed (optional)"

case ":$PATH:" in *":$BIN:"*) ;; *) warn "$BIN is not on PATH yet — log out and back in (Ubuntu adds it at login)";; esac
echo
ok "jumpbox ready. Next: ./01-prepare-nodes.sh"
