# Faza 2 — Research

Pe baza inventarului din `01-inventar.md`. Cercetare făcută via 3 agenți paraleli
(surse primare: release notes, GitHub, docs oficiale — nu bloguri de opinie),
sintetizată și judecată aici în raport cu constrângerile homelab-ului: un
singur operator, R730xd + Beelink + VPS Oracle gratuit, 2-4h/săptămână, zero
cost nou.

**Notă despre profunzime**: layerele flagate ca reale în Faza 0/1 (storage,
backup, observabilitate, DNS, structura repo) au cercetare completă mai jos.
Restul (hardware, hypervisor, rețea/VLAN, VPN, certificate, identitate,
aplicații, automatizare, documentație) nu au ieșit ca probleme în audit —
verdict scurt, fără cercetare externă suplimentară, ca să nu inventez
probleme unde nu s-a semnalat niciuna.

---

## Tabel sumar

| Layer | Ce am acum | Alternative | Recomandare | Verdict |
|---|---|---|---|---|
| Storage (Longhorn) | Longhorn v1.12.0, CSI nativ k8s | Rook-Ceph, OpenEBS Mayastor, democratic-csi, NFS-only | Păstrează — toate alternativele sunt **mai** complexe operațional la 2 hosturi, nu mai simple | **Păstrează** |
| Backup mesh | 4 mecanisme paralele (Longhorn→Garage, ZFS snapshot local, weekly→Synology→Oracle, restic direct nightly) | VolSync+restic/Kopia (standard k8s), Velero+Longhorn CSI plugin | Nu schimba unealta — repară acoperirea (extinde restic-direct peste golurile găsite în Faza 1) | **Consolidează** |
| Proxmox Backup Server | vzdump simplu | PBS local pe R730xd | Nu adăuga — PBS pe hostul pe care-l backup-uiește anulează parțial scopul, la 2 hosturi tot cost, beneficiu mic | **Păstrează** |
| Observabilitate (k8s) | kube-prometheus-stack + Loki + Netdata | — | Standard de facto pt k8s, activ, nu-l schimba | **Păstrează** |
| Observabilitate (VPS) | Beszel + Glances (+ Dozzle documentat dar mort) | Consolidare pe Beszel singur | Glances și rămășița de Netdata/Dozzle ies, Beszel rămâne hub unic pt hosturi non-k8s | **Consolidează** |
| Alertare reală | Doar heartbeat healthchecks.io; rută către om comentată/dezactivată | Pushover (nativ Alertmanager) sau ntfy.sh (webhook) | Activează un receiver real — cel mai mare impact per efort din tot Faza 2 | **Consolidează** |
| DNS local | Pi-hole+Unbound pe VPS, dar absent din DHCP LAN | AdGuard Home | Nu înlocui — repară (bagă-l în DHCP). Comunitatea tratează asta ca bug de config, nu motiv de eliminare | **Păstrează + repară** |
| GitOps (Flux) | Flux v2 (flux-operator/flux-instance) | ArgoCD, fără GitOps | CNCF Graduated, activ, niciun consens că ar fi overkill la scara asta | **Păstrează** |
| Kustomize/Helm | ~100% Helm via app-template | Manifeste brute + Kustomize | Pattern standard în ecosistem, nu un smell | **Păstrează** |
| Secrete (SOPS) | SOPS+AGE | Sealed Secrets, External Secrets Operator | Cel mai puțin "ritual" pt un operator; convenția standard onedr0p | **Păstrează** |
| Structura repo | Fork onedr0p/cluster-template, ~1 an nesincronizat | — | Adoptă conștient 1-2 schimbări de arhitectură din upstream (detalii jos), nu o resincronizare completă | **Consolidează selectiv** |
| Hardware/firmware, hypervisor, rețea/VLAN, VPN, certificate, identitate, aplicații, automatizare, documentație | Proxmox, Talos, pfSense, Tailscale, cert-manager, Authentik, media stack, Ansible+Renovate | — | Niciun semnal de problemă în Faza 1 — nu cercetez alternative pt ce nu e stricat | **Păstrează** |

---

## Detalii per layer

### Storage — Longhorn

Verificat: **activ**, CNCF Incubating, ~2043 contribuitori, release-uri
regulate (v1.12.0 iunie 2026, v1.12.1-rc1 iulie 2026). Footgun-urile
întâlnite azi (blocaj PodSecurity la instalare, replici instabile după
reinstalare nod cu nume nou) sunt **documentate oficial, cu fix cunoscut** —
nu bug-uri active nerezolvate. Cerința oficială e minim 3 noduri pentru
producție (clusterul are exact 3).

Alternativele găsite (Rook-Ceph, OpenEBS Mayastor, democratic-csi) sunt toate
**mai grele** operațional la 2 hosturi fizice — Ceph în special cere mai
multe noduri/discuri dedicate ca să fie sănătos. NFS-only (fără CSI
persistent) ar fi mai simplu, dar se pierde replicarea/snapshot-ul nativ.

**Unealta nu se schimbă.** Complexitatea reală era operațională (incidentul C
din sesiunea de azi), nu de arhitectură — și aia e deja reparată.

### Backup — mesh-ul de 4 mecanisme

Comunitatea homelab (onedr0p și derivate) folosește predominant **VolSync +
restic/Kopia** pentru PVC-uri k8s, nu Velero pentru tot. Pentru Longhorn
specific, **Velero + plugin-ul CSI Longhorn** ar putea înlocui backup-ul
nativ Longhorn→S3 cu avantaj de portabilitate — dar nu ajută la partea de
VM-uri/pfSense, care rămâne oricum în afara k8s-ului.

Dat fiind că mecanismul restic-direct (cel mai nou, cu `restic check`,
deschis, fără dependență DSM) **nu acoperă** exact datele critice
(`longhorn-garage/`, `synology-home/`, `/media/photos` — găsit în Faza 1),
recomandarea practică e: **extinde scope-ul restic-direct peste acele
categorii**, apoi evaluează dacă mai are sens leg-ul săptămânal
Synology→HyperBackup pentru ele, sau devine redundant. Nu introduce un tool
nou (Velero) doar pentru asta — ar adăuga o a 5-a piesă, nu ar simplifica.

### Observabilitate

Nu există în 2026 un singur tool care unifică monitorizarea k8s cu cea de
hosturi/VM-uri — dar suprapunerea din acest setup (Netdata + Beszel + Glances
+ Prometheus/Grafana) e reală și eliminabilă parțial:

- **Beszel** (henrygd/beszel): activ, creștere rapidă, agent sub 10MB RAM,
  gândit exact pentru "câteva servere, un dashboard" — recomandat de
  comunitate ca hub unic pentru partea non-k8s (VPS).
- **Glances**: activ dar e monitor punctual/terminal, nu hub central — poate
  ieși, Beszel acoperă rolul.
- **kube-prometheus-stack**: rămâne singurul loc pentru cluster, e standard.

**Cel mai important găsit**: Alertmanager are `pushover_configs` /
`discord_configs` / webhook generic **native**, fără cod suplimentar — dar
aici ruta reală către om e comentată în cod, doar heartbeat-ul
funcționează. Asta înseamnă că cele 2 HelmRelease-uri Stalled din sesiunea
de azi (immich-postgres, csi-driver-nfs) **n-ar fi alertat pe nimeni** chiar
dacă exista o regulă pentru ele — pentru că nu există deloc un receiver
"critical" activ. Asta e simplificarea cu cel mai mare impact per efort din
toată Faza 2: o singură integrare Pushover/ntfy, minute de config.

### DNS

Nici Pi-hole, nici AdGuard Home nu sunt "mai moarte" — ambele active,
release-uri regulate. Diferența e arhitecturală (AdGuard Home = un singur
binar, fără Unbound separat). Dar comunitatea tratează exact situația de aici
(Pi-hole absent din DHCP LAN) ca **bug de configurare**, nu motiv de
eliminare a proiectului: soluția uzuală e pus Pi-hole ca DNS primar în
DHCP-ul pfSense, nu scoaterea lui. Eliminarea are sens doar dacă se renunță
explicit la ad-blocking la nivel de rețea — nu pare cazul de aici.

### GitOps / Structura repo

Flux v2 e **CNCF Graduated**, activ (2 release-uri deja în H1 2026),
dezvoltat în continuare de ControlPlane/Microsoft/VMware după închiderea
Weaveworks (feb. 2024). Nicio sursă nu sugerează că ar fi overkill la scara
unui singur operator — comparațiile Flux vs ArgoCD cadrează alegerea ca
preferință de workflow (CLI/CR-first vs UI-first), nu ca prag de scală.
Kustomize + Helm ~100% via app-template e pattern standard, nu un smell.
SOPS+AGE e convenția implicită a familiei onedr0p, cu cel mai puțin "ritual"
de întreținere pentru un singur operator (o singură cheie de păzit) față de
Sealed Secrets (cheie regenerată la fiecare rebuild de cluster, dacă nu e
salvată separat) sau External Secrets Operator (adaugă o dependență externă
care nu există deja în acest setup).

**Găsire directă și relevantă**: `onedr0p/cluster-template` (repo-ul din care
acest fork a pornit acum ~1 an) a **eliminat exact pattern-ul de "namespace
component comun"** într-un release din 2025 (2025.11.0) — adică exact clasa
de bug întâlnită azi la Longhorn (două Kustomization-uri Flux declarând
concurent același Namespace). Nu e coincidență — probabil au lovit aceeași
problemă și au renunțat la pattern. Merită verificat direct PR-ul upstream
pentru motivul exact, dar semnalul e clar: **e o schimbare de adoptat
conștient**, nu doar la Longhorn ci verificată sistematic în tot repo-ul
(semnalat deja `default/portainer-agent/app/namespace.yaml` ca alt candidat
cu același risc, în `01-inventar.md`).

Alte schimbări upstream din acest an, de evaluat fără urgență: bootstrap
flux-operator/instance mai granular (HelmRelease-uri/OCIRepository-uri
separate în loc de monolitice — parțial deja prezente aici), migrare la
chart-ul OCI oficial Cilium, tooling modernizat (config TOML, `justfile` în
loc de Taskfile). Niciuna nu e urgentă — sunt opțiuni pentru Faza 3, nu
probleme.

---

## Presupuneri și ce ar fi îmbunătățit acest research

- Am presupus că "consolidează" observabilitatea înseamnă păstrarea a 2
  dashboard-uri separate (k8s + VPS), nu unul singur — pentru că niciun
  research n-a găsit un tool matur care le unifică azi. Dacă asta contrazice
  ce-ți doreai, spune-mi.
- N-am citit PR-ul exact din onedr0p/cluster-template care a eliminat
  namespace component-ul comun — doar am observat că s-a întâmplat. Dacă
  vrei motivul exact înainte de Faza 3, pot săpa mai adânc.
- N-am cercetat separat layerele fără probleme semnalate (hardware, VLAN,
  identitate etc.) — dacă vrei acoperire completă pe toate 14, spune-mi și
  fac o trecere dedicată, dar cred că ar fi efort fără câștig la ce știm
  acum.
