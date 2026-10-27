#!/usr/bin/env bash
# Module 12: from "a cluster with nodes" to "ArgoCD owns the cluster".
# Safe to re-run: every step converges, none recreates.
#
#   ./bootstrap/bootstrap.sh
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
GATEWAY_API_VERSION=v1.6.3

for c in kubectl helm helmfile; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done
kubectl get --raw /readyz >/dev/null || { echo "no cluster answers — check KUBECONFIG" >&2; exit 1; }

echo "→ Gateway API CRDs ${GATEWAY_API_VERSION}"
# --force-conflicts: on a re-run ArgoCD already owns these fields; take them back.
kubectl apply --server-side --force-conflicts -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml" >/dev/null

echo "→ helmfile: cilium → coredns → argocd"
helmfile --file bootstrap/helmfile.yaml sync --hide-notes

echo "→ root Application (from here on, Git is the only way in)"
kubectl apply -f argocd/root.yaml

kubectl -n argocd rollout status deploy/argocd-server --timeout=5m >/dev/null
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
echo
echo "✓ ArgoCD is reconciling $(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l) application(s)."
echo "  UI:  kubectl -n argocd port-forward svc/argocd-server 8080:80   →  http://localhost:8080"
echo "  admin / ${PASS:-<already rotated>}"
echo "  CLI: argocd login localhost:8080 --plaintext --username admin"
