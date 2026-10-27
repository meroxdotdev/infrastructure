#!/usr/bin/env bash
# Module 06, step 03 — a kubeconfig is three things glued together: where the
# API is (server + the CA to trust it), who you are (a client cert), and a
# context naming the pair. The user *name* inside is a local label only; the
# API learns who you are from the certificate's CN and O, nothing else.
#
#   admin, kubelets      → the VIP: they must survive any one node dying
#   controller-manager,
#   scheduler            → 127.0.0.1: they run next to an apiserver, and
#                          talking to the local one keeps them working while
#                          the VIP moves
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl
require_file "$PKI/ca.crt" "$PKI/admin.crt"

mkdir -p "$KC"
umask 077

# mk <name> <server-url> <cert-basename>
mk() {
  local name=$1 server=$2 cert=$3 out="$KC/$1.kubeconfig"
  if [[ -f $out ]]; then return 0; fi
  kubectl config set-cluster "$CLUSTER_NAME" --kubeconfig="$out" \
    --certificate-authority="$PKI/ca.crt" --embed-certs=true --server="$server" >/dev/null
  kubectl config set-credentials "$name" --kubeconfig="$out" \
    --client-certificate="$PKI/$cert.crt" --client-key="$PKI/$cert.key" --embed-certs=true >/dev/null
  kubectl config set-context default --kubeconfig="$out" --cluster="$CLUSTER_NAME" --user="$name" >/dev/null
  kubectl config use-context default --kubeconfig="$out" >/dev/null
  ok "$(printf '%-28s' "$name.kubeconfig") → $server"
}

VIP="https://${API_VIP}:${API_PORT}"
LOCAL="https://127.0.0.1:${API_PORT}"

mk admin "$VIP" admin
mk controller-manager "$LOCAL" controller-manager
mk scheduler "$LOCAL" scheduler
for n in "${NODES[@]}"; do mk "kubelet-${n}" "$VIP" "kubelet-${n}"; done

mkdir -p "$HOME/.kube"
if [[ ! -f $HOME/.kube/config ]]; then
  cp "$KC/admin.kubeconfig" "$HOME/.kube/config"
  ok "~/.kube/config = admin (it will answer once module 07 is done)"
fi

# etcdctl reads ETCDCTL_* from the environment: source this to talk to etcd.
cat >"$WORKDIR/etcdctl.env" <<EOF
export ETCDCTL_ENDPOINTS=$(endpoints 2379)
export ETCDCTL_CACERT=$PKI/etcd/ca.crt
export ETCDCTL_CERT=$PKI/etcd/etcdctl.crt
export ETCDCTL_KEY=$PKI/etcd/etcdctl.key
EOF
ok "source $WORKDIR/etcdctl.env  # for etcdctl"
ok "Next: ./04-etcd.sh"
