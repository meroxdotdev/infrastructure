#!/usr/bin/env bash
# Module 06, step 02 — the cluster's PKI, built on the jumpbox. kubeadm does
# this in `kubeadm init phase certs all`; Talos does it from talsecret.sops.yaml.
#
#   kubernetes-ca ─┬─ apiserver                  server: what every client of :6443 checks
#                  ├─ apiserver-kubelet-client   apiserver → kubelet (logs, exec, port-forward)
#                  ├─ controller-manager         client, CN=system:kube-controller-manager
#                  ├─ scheduler                  client, CN=system:kube-scheduler
#                  ├─ admin                      client, O=system:masters (break-glass)
#                  ├─ kubelet-<node>             client, CN=system:node:<node>, O=system:nodes
#                  └─ kubelet-<node>-serving     server, presented by the kubelet on :10250
#   etcd-ca ───────┬─ etcd/<node>-server         server+client, etcd's :2379
#                  ├─ etcd/<node>-peer           server+client, etcd member ⇄ member on :2380
#                  ├─ apiserver-etcd-client      the only etcd client in normal operation
#                  └─ etcd/etcdctl               you, with etcdctl
#   front-proxy-ca ─ front-proxy-client          apiserver → aggregated APIs (metrics-server)
#   sa.key / sa.pub                              not a certificate: signs ServiceAccount tokens
#   encryption.key                               not a certificate: encrypts Secrets in etcd
#
# Three CAs, not one, because trust is per CA: anything signed by etcd-ca can
# talk to etcd, so nothing else may be signed by it.
#
# Idempotent: an existing file is never replaced. Start over: rm -rf "$WORKDIR/pki"
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
need openssl

mkdir -p "$PKI/etcd"
cd "$PKI"
umask 077

# ECDSA P-256: small, fast, supported by every Kubernetes component.
key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }

# ca <path> <CN>
ca() {
  local out=$1 cn=$2
  if [[ -f $out.crt ]]; then return 0; fi
  key "$out.key"
  openssl req -x509 -new -key "$out.key" -sha256 -days 3650 -subj "/CN=$cn" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$out.crt"
  ok "CA   $cn"
}

# cert <path> <ca-path> <subject> <server|client|both> [subjectAltName]
cert() {
  local out=$1 ca=$2 subj=$3 usage=$4 san=${5:-} eku ext
  if [[ -f $out.crt ]]; then return 0; fi
  case $usage in
    server) eku=serverAuth ;;
    client) eku=clientAuth ;;
    both) eku=serverAuth,clientAuth ;;
    *) die "usage must be server|client|both" ;;
  esac
  ext=$(mktemp)
  {
    echo "basicConstraints=critical,CA:FALSE"
    echo "keyUsage=critical,digitalSignature"
    echo "extendedKeyUsage=$eku"
    echo "subjectKeyIdentifier=hash"
    echo "authorityKeyIdentifier=keyid"
    if [[ -n $san ]]; then echo "subjectAltName=$san"; fi
  } >"$ext"
  key "$out.key"
  openssl req -new -key "$out.key" -subj "$subj" -out "$out.csr"
  openssl x509 -req -in "$out.csr" -CA "$ca.crt" -CAkey "$ca.key" -CAcreateserial \
    -days 365 -sha256 -extfile "$ext" -out "$out.crt" 2>/dev/null
  rm -f "$ext" "$out.csr"
  ok "cert $(printf '%-30s' "$out") $subj"
}

ca ca "kubernetes-ca"
ca etcd/ca "etcd-ca"
ca front-proxy-ca "front-proxy-ca"

# Every name and address a client may use to reach the API. A client that
# dials a name missing from this list gets "x509: certificate is valid for …,
# not …" — prod's additionalApiServerCertSans exists for exactly this.
API_SANS="DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc"
API_SANS+=",DNS:kubernetes.default.svc.${CLUSTER_DOMAIN},DNS:api.${LAB_DOMAIN}"
API_SANS+=",IP:${KUBERNETES_SVC_IP},IP:${API_VIP},IP:127.0.0.1"
for n in "${NODES[@]}"; do API_SANS+=",DNS:${n},IP:${NODE_IP[$n]}"; done

cert apiserver ca "/CN=kube-apiserver" server "$API_SANS"
cert apiserver-kubelet-client ca "/CN=kube-apiserver-kubelet-client" client
cert apiserver-etcd-client etcd/ca "/CN=kube-apiserver-etcd-client" client
cert front-proxy-client front-proxy-ca "/CN=front-proxy-client" client
cert controller-manager ca "/CN=system:kube-controller-manager" client
cert scheduler ca "/CN=system:kube-scheduler" client
cert admin ca "/O=system:masters/CN=admin" client
cert etcd/etcdctl etcd/ca "/CN=etcdctl" client

for n in "${NODES[@]}"; do
  ip=${NODE_IP[$n]}
  cert "etcd/${n}-server" etcd/ca "/CN=${n}" both "DNS:${n},DNS:localhost,IP:${ip},IP:127.0.0.1"
  cert "etcd/${n}-peer" etcd/ca "/CN=${n}" both "DNS:${n},IP:${ip}"
  cert "kubelet-${n}" ca "/O=system:nodes/CN=system:node:${n}" client
  cert "kubelet-${n}-serving" ca "/CN=${n}" server "DNS:${n},IP:${ip}"
done

if [[ ! -f sa.key ]]; then
  key sa.key
  openssl pkey -in sa.key -pubout -out sa.pub 2>/dev/null
  ok "sa.key / sa.pub"
fi

if [[ ! -f encryption.key ]]; then
  head -c 32 /dev/urandom | base64 >encryption.key
  ok "encryption.key (32 random bytes, base64)"
fi

echo
ok "PKI in $PKI. Read one:  openssl x509 -in $PKI/apiserver.crt -noout -text | less"
ok "Next: ./03-kubeconfigs.sh"
