#!/usr/bin/env bash
# Render every Application the way ArgoCD's repo-server would — helm template
# for chart sources, kustomize for path sources — and validate the result.
# Runs in CI (validate.yaml) and locally: bash scripts/validate.sh
set -Eeuo pipefail
cd "$(git rev-parse --show-toplevel)"

for c in yq helm kubectl kubeconform; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

render_chart() { # <out> <repoURL> <chart> <version> <release> [values]
  local out=$1 repo=$2 chart=$3 version=$4 release=$5 values=${6:-}
  local src=()
  if [[ $repo == http* ]]; then src=(--repo "$repo" "$chart"); else src=("oci://${repo}/${chart}"); fi
  local vals=()
  if [[ -n $values ]]; then vals=(-f "$values"); fi
  helm template "$release" "${src[@]}" --version "$version" "${vals[@]}" --include-crds >"$out"
}

shopt -s nullglob
for f in argocd/apps/*.yaml argocd/later/*.yaml; do
  [[ $(yq '.kind' "$f") == Application ]] || continue
  name=$(yq '.metadata.name' "$f")
  count=$(yq '.spec.sources | length' "$f")
  for ((i = 0; i < count; i++)); do
    chart=$(yq ".spec.sources[$i].chart // \"\"" "$f")
    path=$(yq ".spec.sources[$i].path // \"\"" "$f")
    if [[ -n $chart ]]; then
      repo=$(yq ".spec.sources[$i].repoURL" "$f")
      version=$(yq ".spec.sources[$i].targetRevision" "$f")
      release=$(yq ".spec.sources[$i].helm.releaseName // \"$name\"" "$f")
      values=$(yq ".spec.sources[$i].helm.valueFiles[0] // \"\"" "$f")
      values=${values#\$values/}
      echo "→ ${name}: ${chart}@${version}"
      render_chart "$OUT/${name}-${i}.yaml" "$repo" "$chart" "$version" "$release" "$values"
    elif [[ -n $path ]]; then
      echo "→ ${name}: ${path}"
      kubectl kustomize "$path" >"$OUT/${name}-${i}.yaml"
    fi
  done
done

for d in apps/*/ apps-later/*/; do
  echo "→ $(basename "$d"): ${d}"
  kubectl kustomize "$d" >"$OUT/app-$(basename "$d").yaml"
done

# CRDs Kubernetes does not know come from the community catalog; anything in
# neither is skipped, not failed, and the summary says how many.
kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "$OUT"/*.yaml
