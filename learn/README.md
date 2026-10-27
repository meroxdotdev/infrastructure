# learn/ — K8s Learn Lab

Un curs practic, construit pe acest repo: de la un proces Linux la un cluster
Kubernetes HA, construit de mână, cu BGP, ArgoCD și CI/CD — și, la fiecare pas,
comparat cu ce rulează în producție aici.

## Pornește interfața

```bash
python learn/serve.py          # din rădăcina repo-ului → http://127.0.0.1:8080/learn/
```

Serverul pornește din rădăcina repo-ului ca lecțiile să poată deschide fișierele
reale (`talos/talconfig.yaml`, `kubernetes/apps/...`) într-un viewer. Ascultă doar
pe `127.0.0.1` și refuză căile care pot conține secrete (`age.key`, `kubeconfig`,
`talosconfig`, `.private/`, `*.tfvars`…) — un `python -m http.server` simplu le-ar
servi oricui ajunge la port.

Interfața îți dă: progresul pe taskuri (bifezi direct în lecție), notițe pe
modul, căutare în tot cursul (`/`), și viewer pentru fișierele din repo. Progresul
stă în `localStorage` — exportă-l din pagina principală dacă schimbi browserul.

Lecțiile sunt Markdown simplu: se citesc și pe GitHub, fără interfață.

## Structura

```
learn/
├── index.html, assets/      interfața (fără build, fără dependențe locale)
├── serve.py                 serverul local, cu lista de căi blocate
├── curriculum.json          modulele: titlu, fază, obiective, ore estimate
├── docs/                    lecțiile, 00–19, plus glosar și fișa de comenzi
└── lab/                     tot ce rulezi: Terraform, scripturi, repo-ul GitOps
```

## Convențiile din lecții

| În Markdown | Înseamnă |
|---|---|
| `- [ ] …` | un task; în interfață se bifează și se salvează |
| `> [!TIP]` | 🧠 analogie |
| `> [!NOTE]` | 🏠 cum e în producție, în repo-ul ăsta |
| `> [!IMPORTANT]` | ❓ de ce — motivul din spatele unei alegeri |
| `> [!WARNING]` | ⚠️ capcană în care cad aproape toți |
| `> [!CAUTION]` | 💥 comandă distructivă |
| `<details>` | întrebare de verificare; răspunsul e ascuns până dai click |

## Ce construiești

Trei VM-uri Ubuntu pe Proxmox, plus un router. Kubernetes instalat **fără**
kubeadm și **fără** Talos — fiecare certificat și fiecare unit systemd de mână —
apoi Cilium cu BGP spre un router FRR, ArgoCD în loc de Flux, Longhorn cu backup
pe S3, Prometheus, și un pipeline care duce un `git push` până într-un pod.
La final distrugi tot și îl reconstruiești din Git, ca în `DR.md`.

Începe cu [docs/00-start.md](docs/00-start.md).
