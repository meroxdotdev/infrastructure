# k8s-lab — the lab's GitOps repository

Template for a **separate** repository that ArgoCD watches. It plays the role
`kubernetes/` plays in `meroxdotdev/infrastructure`, with ArgoCD instead of Flux.
Separate, because you will break it on purpose, and because ArgoCD, CI and
Renovate each need a repo of their own to show how they work.

```bash
cp -r learn/lab/k8s-lab ~/Projects/k8s-lab && cd ~/Projects/k8s-lab
git init -b main && git add -A && git commit -m "feat: k8s-lab from learn/lab template"
gh repo create meroxdotdev/k8s-lab --public --source=. --push
```

Another owner or name? Replace it everywhere before the first push:

```bash
grep -rl 'meroxdotdev/k8s-lab' . | xargs sed -i 's#meroxdotdev/k8s-lab#<owner>/<repo>#g'
grep -rl 'ghcr.io/meroxdotdev' . | xargs sed -i 's#ghcr.io/meroxdotdev#ghcr.io/<owner>#g'
```

## Layout

| Path | Role | Prod equivalent |
|---|---|---|
| `bootstrap/` | helmfile + script: Cilium, CoreDNS, ArgoCD, then the root app | `bootstrap/helmfile.yaml`, `scripts/bootstrap-apps.sh` |
| `argocd/root.yaml` | the one Application applied by hand | `kubernetes/flux/cluster/ks.yaml` |
| `argocd/apps/` | one Application per platform component, ordered by sync waves | every `ks.yaml` |
| `argocd/later/` | components the course turns on later — `git mv` one into `apps/` | — |
| `platform/<name>/` | Helm values (`values.yaml`) and extra manifests (`config/`) | `kubernetes/apps/<ns>/<app>/app/` |
| `apps/` | workloads; one directory = one Application (ApplicationSet) | `kubernetes/apps/default/` |
| `apps-later/` | workloads the course adds later | — |
| `src/lab-app/` | the demo service CI builds | — |
| `.github/workflows/` | validate manifests; build, sign, deploy lab-app | `.github/workflows/flux-local.yaml` |

The course is in `learn/docs/` of the infrastructure repo — module 12 starts here.
