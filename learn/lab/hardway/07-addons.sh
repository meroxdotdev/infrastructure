#!/usr/bin/env bash
# Module 08, step 07 — the two add-ons a cluster cannot work without: a CNI
# (Cilium, which also replaces kube-proxy) and DNS (CoreDNS).
#
# Installed with plain helm here, from the *same* values files ArgoCD will use
# in module 12 (learn/lab/k8s-lab/platform/). That is prod's pattern too:
# bootstrap/helmfile.yaml reads kubernetes/apps/.../helm/values.yaml, so the
# bootstrap and the GitOps release can never disagree.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl helm cilium

PLATFORM="${LAB_DIR}/k8s-lab/platform"
# renovate: datasource=docker depName=ghcr.io/coredns/charts/coredns
COREDNS_CHART_VERSION=1.49.0

# Gateway API CRDs before Cilium: its operator checks for them at start-up and
# only enables the Gateway controller if they are already there.
log "Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml" >/dev/null
ok "gateway-api CRDs"

log "Cilium ${CILIUM_CHART_VERSION}"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium --version "${CILIUM_CHART_VERSION}" \
  --namespace kube-system -f "${PLATFORM}/cilium/values.yaml" --wait --timeout 10m
cilium status --wait --wait-duration 5m

log "CoreDNS ${COREDNS_CHART_VERSION}"
helm upgrade --install coredns oci://ghcr.io/coredns/charts/coredns --version "${COREDNS_CHART_VERSION}" \
  --namespace kube-system -f "${PLATFORM}/coredns/values.yaml" --wait --timeout 5m

kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
ok "cluster up. Smoke test: docs/08-hardway-noduri-cilium.md, section 'Testul de fum'"
