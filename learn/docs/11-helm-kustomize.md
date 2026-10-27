# Helm și Kustomize

Până acum ai scris YAML de mână. În prod sunt ~200 de fișiere, și aproape niciunul nu
e YAML „final” — sunt **valori** pentru un chart Helm sau **bucăți** pe care Kustomize
le asamblează. Înainte de ArgoCD trebuie să știi exact ce produc, pentru că ArgoCD nu
face altceva decât să ruleze aceste două unelte și să aplice rezultatul.

## Două filozofii

| | Helm | Kustomize |
|---|---|---|
| Ideea | **șabloane**: YAML cu goluri, umplute din `values.yaml` | **suprapuneri**: YAML valid, modificat cu patch-uri |
| Unitatea | un *chart* versionat, publicat într-un repo/registry | un director cu `kustomization.yaml` |
| Logică | condiții, bucle, funcții (Go templates) | niciuna, intenționat |
| Stare în cluster | o *release*, stocată ca Secret (`sh.helm.release.v1.*`) | niciuna |
| Bun pentru | să distribui software altora (Cilium, Longhorn) | să-ți adaptezi propriile manifeste |
| Rău pentru | a citi ce se va aplica, fără să randezi | a genera multe resurse similare |

> [!TIP]
> **🧠 Analogie: formularul vs. creionul roșu**
> Helm e un **formular tipizat**: autorul a hotărât ce câmpuri poți completa (`values`),
> iar tu nu poți schimba nimic altceva decât dacă autorul a lăsat un câmp pentru asta.
> Kustomize e un **document gata scris plus un creion roșu**: pornești de la un text
> valid și tai, adaugi, modifici unde vrei — dar nu poți genera o pagină nouă din nimic.
> Prod le folosește pe amândouă împreună: formularul pentru software-ul altora, creionul
> pentru al tău.

## Helm

```
cilium/
├── Chart.yaml          nume, versiune, dependențe
├── values.yaml         toate valorile implicite — documentația reală a chart-ului
├── templates/          YAML cu {{ .Values.x }}, {{ include "..." }}, {{ if }}, {{ range }}
│   └── _helpers.tpl    funcții reutilizabile
└── crds/               CRD-uri: instalate la install, NICIODATĂ actualizate la upgrade
```

Comenzile care îți spun adevărul:

```bash
helm show values cilium/cilium --version 1.20.4 | less          # ce poți seta
helm template cilium cilium/cilium --version 1.20.4 \
  -f ~/infrastructure/learn/lab/k8s-lab/platform/cilium/values.yaml -n kube-system > /tmp/cilium.yaml
grep -c '^kind:' /tmp/cilium.yaml                                  # câte obiecte
grep '^kind:' /tmp/cilium.yaml | sort | uniq -c
helm -n kube-system list
helm -n kube-system get values cilium                              # ce ai setat tu
helm -n kube-system history cilium
kubectl -n kube-system get secret -l owner=helm                    # starea release-urilor
```

> [!WARNING]
> **⚠️ CRD-urile din `crds/` nu se actualizează**
> Helm le instalează o dată și nu le mai atinge — ca să nu șteargă din greșeală date.
> Chart-urile mari ocolesc asta punând CRD-urile în `templates/` după un flag
> (`crds.enabled: true` la cert-manager și kube-prometheus-stack), sau cu un Job.
> Prod forțează `crds: CreateReplace` pentru toate HelmRelease-urile, din
> [cluster/ks.yaml](../../kubernetes/flux/cluster/ks.yaml) — un patch aplicat tuturor.

### app-template: un chart pentru toate aplicațiile

Majoritatea aplicațiilor din prod nu au chart propriu: folosesc **app-template**
(bjw-s), un chart generic în care descrii controllere, containere, service, route,
persistență — și el generează Deployment, Service, HTTPRoute, PVC-uri. Randează-l pe
Radarr:

```bash
cd ~/infrastructure
yq '.spec.values' kubernetes/apps/default/radarr/app/helmrelease.yaml > /tmp/radarr-values.yaml
helm template radarr oci://ghcr.io/bjw-s-labs/helm/app-template --version 5.3.0 \
  -f /tmp/radarr-values.yaml > /tmp/radarr.yaml
grep -E '^kind:|^  name:' /tmp/radarr.yaml
grep -n 'NAS_SERVER' /tmp/radarr.yaml
```

Ultimul `grep` găsește `server: ${NAS_SERVER}` **neînlocuit**. Helm nu știe nimic de
el: e o variabilă **Flux** (`postBuild.substituteFrom: cluster-vars` din
[ks.yaml-ul Radarr](../../kubernetes/apps/default/radarr/ks.yaml)), înlocuită *după*
randare. Ține minte asta — în modulul 12 vei vedea că ArgoCD nu are un echivalent direct.

## Kustomize

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-app                 # transformator: pune namespace-ul pe tot
resources: [deployment.yaml, …]    # ce intră
components: [../../components/x]   # bucăți reutilizabile care pot și modifica
patches: [{path: x.yaml, target: {kind: Deployment}}]
labels: [{pairs: {team: lab}}]
configMapGenerator: [{name: cfg, literals: [A=1]}]   # → cfg-<hash>
images: [{name: app, newName: ghcr.io/x/app, digest: sha256:…}]
```

```bash
kubectl kustomize ~/infrastructure/learn/lab/k8s-lab/apps-later/lab-app | less
```

Observă trei lucruri în ieșire: namespace-ul `lab-app` pe fiecare obiect; ConfigMap-ul
numit `lab-app-<hash>` **și** referința din Deployment rescrisă la același nume;
imaginea `lab-app` înlocuită cu `ghcr.io/meroxdotdev/lab-app:latest`.

> [!IMPORTANT]
> **❓ De ce hash-ul din numele ConfigMap-ului e o idee bună**
> Pod-urile citesc variabilele de mediu doar la pornire. Dacă schimbi conținutul unui
> ConfigMap cu nume fix, pod-urile care rulează nu află. Cu hash, conținut nou = nume
> nou = pod template nou = rollout automat, și un rollback readuce și configurația
> veche. Prod rezolvă aceeași problemă altfel: Reloader
> (`reloader.stakater.com/auto: "true"`). Dar prod folosește și varianta Kustomize, în
> sens invers: `disableNameSuffixHash: true` pentru regulile Loki din
> [kustomization-ul Radarr](../../kubernetes/apps/default/radarr/app/kustomization.yaml),
> pentru că acolo Loki caută ConfigMap-ul după un nume fix.

### Cum e construit prod-ul cu Kustomize

Randează un namespace întreg din prod, exact cum îl vede Flux:

```bash
cd ~/infrastructure
kubectl kustomize kubernetes/apps/default | grep -E '^kind:' | sort | uniq -c
```

Nu vezi Deployment-uri. Vezi `Kustomization` (obiectele **Flux**, câte unul pe aplicație,
din fiecare `ks.yaml`), `OCIRepository`, un `ConfigMap` `cluster-vars`, `Secret`-uri SOPS,
un `Namespace` și politica de rețea. Acesta e stratul de **orchestrare**: fiecare
`Kustomization` Flux arată spre directorul `app/` al aplicației, pe care Flux îl randează
separat, cu propriile dependențe (`dependsOn: longhorn`).

[components/common](../../kubernetes/components/common/kustomization.yaml) e un
**Component**: o bucată inclusă în fiecare namespace (`components: [../../components/common]`),
care aduce `cluster-vars`, secretele SOPS, repo-ul app-template și un Namespace „not-used”
pe care transformatorul `namespace:` îl redenumește în namespace-ul curent. Comentariul din
[default/kustomization.yaml](../../kubernetes/apps/default/kustomization.yaml) explică o
subtilitate: patch-ul pentru etichetele PodSecurity trebuie să țintească numele **dinainte**
de redenumire, pentru că patch-urile se potrivesc înaintea transformatorului.

### Helm și Kustomize împreună

Cilium din prod e ambele. [kustomization.yaml](../../kubernetes/apps/kube-system/cilium/app/kustomization.yaml)
generează un ConfigMap `cilium-values-<hash>` din `helm/values.yaml`, iar
[kustomizeconfig.yaml](../../kubernetes/apps/kube-system/cilium/app/helm/kustomizeconfig.yaml)
îi spune lui Kustomize că `spec.valuesFrom.name` dintr-un HelmRelease e o *referință la un
ConfigMap* — deci să o rescrie cu numele cu hash. Rezultatul: modifici `values.yaml`, numele
ConfigMap-ului se schimbă, HelmRelease-ul se schimbă, Flux face upgrade. Iar
[bootstrap/helmfile.yaml](../../bootstrap/helmfile.yaml) citește **același** `values.yaml`
direct — bootstrap-ul și GitOps-ul nu pot diverge.

Lab-ul face același lucru cu ArgoCD și *multi-source* (modulul 12): chart-ul din repo-ul
Cilium, valorile din `$values/platform/cilium/values.yaml`.

## Laborator

```bash
# 1. Un release Helm, upgrade, rollback — și unde stă starea.
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm install demo podinfo/podinfo -n helmlab --create-namespace --set replicaCount=2
helm upgrade demo podinfo/podinfo -n helmlab --set replicaCount=3 --set ui.message="v2"
helm -n helmlab history demo
helm -n helmlab rollback demo 1
kubectl -n helmlab get secret -l owner=helm -o name
kubectl -n helmlab get secret sh.helm.release.v1.demo.v1 -o jsonpath='{.data.release}' | base64 -d | base64 -d | gzip -d | jq '.config'

# 2. Ce se întâmplă dacă modifici de mână un obiect gestionat de Helm?
kubectl -n helmlab scale deploy demo-podinfo --replicas=5
helm -n helmlab upgrade demo podinfo/podinfo --reuse-values     # înapoi la valoarea din release? verifică
kubectl -n helmlab get deploy demo-podinfo
helm uninstall demo -n helmlab && kubectl delete namespace helmlab
```

A doua parte merită atenție: Helm 3+ face un *three-way merge* (manifestul vechi, cel nou,
starea din cluster). Rezultatul depinde de ce s-a schimbat între release-uri — nu e o
reconciliere continuă. **Asta** e diferența față de un controller GitOps: Helm aplică o
dată; ArgoCD sau Flux readuc starea dorită la fiecare câteva minute.

## Taskuri

- [ ] `helm template` pentru Cilium cu valorile lab-ului; numără obiectele pe tip
- [ ] Găsește în ieșirea randată ConfigMap-ul `cilium-config` și cheia corespunzătoare lui `routing-mode`
- [ ] Randează Radarr din prod cu app-template și listează obiectele generate
- [ ] Explică de ce `${NAS_SERVER}` rămâne neînlocuit și cine îl înlocuiește în prod
- [ ] `kubectl kustomize apps-later/lab-app`: găsește hash-ul ConfigMap-ului; schimbă `MESSAGE` și arată că hash-ul se schimbă
- [ ] `kubectl kustomize kubernetes/apps/default` din prod: ce tipuri de obiecte produce, și de ce nu sunt Deployment-uri?
- [ ] Citește `kustomizeconfig.yaml` al Cilium și explică în notițe de ce există
- [ ] Laborator Helm: install, upgrade, rollback, decodează release secret-ul
- [ ] Scalează de mână un Deployment gestionat de Helm și explică ce face (și ce nu face) următorul `helm upgrade`

## Întrebări de verificare

<details>
<summary>Ai nevoie de 30 de Deployment-uri aproape identice, care diferă printr-un nume și o imagine. Helm sau Kustomize?</summary>

Helm (sau un generator ca ApplicationSet, modulul 12). Kustomize nu are bucle: ar
însemna 30 de directoare cu patch-uri. Helm face un `range` peste o listă. Invers, dacă ai
un singur set de manifeste și trei medii care diferă printr-un număr de replici și un
domeniu, Kustomize cu overlay-uri e mai clar decât un chart scris doar pentru tine.
</details>

<details>
<summary>De ce bootstrap-ul prod citește același `values.yaml` ca HelmRelease-ul?</summary>

Pentru că altfel ar exista două adevăruri despre cum arată Cilium. Bootstrap-ul instalează
Cilium cu valorile A; Flux preia release-ul și aplică valorile B; prima reconciliere ar
schimba CNI-ul unui cluster abia pornit. Cu un singur fișier, preluarea e un no-op. Lab-ul
aplică regula de trei ori: `07-addons.sh`, `bootstrap/helmfile.yaml` și Application-ul
`cilium` citesc același fișier.
</details>

<details>
<summary>Ce stochează Helm în Secretul `sh.helm.release.v1.<nume>.v<N>`?</summary>

Release-ul complet, comprimat: chart-ul, valorile folosite, manifestul randat, starea și
notele. Așa știe Helm ce a aplicat data trecută (pentru three-way merge și rollback) fără
să recalculeze. Consecința: un `helm uninstall` șterge tot ce e în manifestul ultimei
revizii. În modulul 12 vei vedea de ce, după ce ArgoCD preia un release, nu mai rulezi
`helm uninstall` niciodată.
</details>
