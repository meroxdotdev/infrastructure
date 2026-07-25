# Faza 1 — Inventar real (audit read-only, 2026-07-25)

Audit făcut prin SSH direct pe R730xd, Beelink/px-0, cluster Talos (`kubectl`
local cu `./kubeconfig`), Oracle VPS și pfSense (acces neașteptat, dar
disponibil). Nicio comandă distructivă, nicio schimbare de configurație.
iDRAC nu a fost auditat direct — vezi secțiunea finală. **Home Assistant e
scos explicit din scope** (decizie user, 2026-07-25): rămâne doar ca fapt în
inventar, nu ca subiect de simplificare — vezi nota din secțiunea 5.

---

## 0. De reparat acum (înainte de Faza 2)

Patru descoperiri din audit nu erau teme de research — erau incidente
active sau riscuri latente. Trei sunt rezolvate (D, B, C); A rămâne deschis.

| # | Ce e | Status | Cum s-a rezolvat |
|---|------|--------|-------------------|
| A | `immich-postgres` HelmRelease **Stalled** din 2026-07-25 (07:00) — upgrade eșuat, Flux a făcut rollback la v5 | **Rezolvat** | Cauza reală: `ghcr.io/tensorchord/cloudnative-vectorchord` 15→17 (Postgres 15→17, două versiuni majore), PR Renovate **merge manual de user** la 06:55 (nu automerge — confirmat via GitHub API, `merged_by: meroxdotdev`, `auto_merge: None`), într-un lot de PR-uri de rutină. Postgres n-a putut porni pe data dir-ul vechi; Flux a făcut rollback automat de 2 ori, fără să atingă datele. Fix: pin la `15-0.3.0` (no-op, zero risc — se potrivește exact cu ce rula deja), plus regulă Renovate nouă (`dependencyDashboardApproval: true` doar pentru bump-uri majore pe acest pachet). Migrarea reală 15→17 rămâne opțiune pe hârtie pentru Faza 2, nu task |
| B | `csi-driver-nfs` HelmRelease **Stalled** de 2 zile — `StorageClass nfs-slow` cu `parameters.share` imutabil, cale Synology moartă (0 PVC-uri o foloseau) | **Rezolvat** | `share` actualizat la `/media/library`; Helm avea istoric stricat (rollback etern la o revizie și mai veche, cu `server: 10.57.57.201` Synology) → `helm uninstall` + install curat. `Ready: True`, pod-uri CSI sănătoase, Jellyfin/Immich neatinse (verificat) |
| C | Labelul PodSecurity pe `longhorn-system` nu ajungea pe namespace-ul live, deși sursa era corectă | **Rezolvat** | Root-cause real: `longhorn/app/kustomization.yaml` declara un `Namespace` propriu, care se ciocnea cu placeholder-ul din `components/common` aplicat de `cluster-apps` — exact anti-pattern-ul pe care `default/kustomization.yaml` îl documenta deja ca evitat. Mutat labelurile într-un `patches:` peste placeholder (ca la `default`), scoasă declarația concurentă. Testat cu reconcile repetat, ordine variată, 3 runde — stabil. Longhorn sănătos pe tot parcursul |
| D | `restore-drill.sh` (VPS) avea `HC_URL=""` și niciun log de execuție | **Rezolvat** | Era WIP necomis de pe 24 iulie (recunoscut de user) — reconciliat cu Mac-ul, cele 4 healthchecks.io URL-uri adăugate în vault, `ansible-playbook --tags backup` rulat. Toate 4 scripturi (extras/joplin/push-r730xd/restore-drill) alertează acum |

Commit-uri: `ce9e70b` (backup alerting), `f87d899` (nfs-slow share),
`ae6897c` + `28cf1e4` (longhorn namespace ownership), `1fb0182`
(immich-postgres pin + regulă Renovate).

**Toate 4 incidentele închise, 2026-07-25.** Verificare finală: toate
HelmRelease-urile din cluster (30) `Ready: True`, toate Kustomization-urile
Flux `Ready: True`, toate volumele Longhorn `healthy`.

---

## 1. Harta reală

### R730xd (`pve`, `10.57.57.250`) — Proxmox 9.2.4, kernel 7.0.14-5

- **Up 4 zile** — deja repornit (nu mai e "pending reboot" cum zicea nota
  veche de memorie).
- **IOMMU/VFIO: ACTIV** — `intel_iommu=on iommu=pt` în cmdline,
  `vfio_pci`/`vfio_iommu_type1` încărcate, **niciun driver nvidia/nouveau pe
  host** → GPU passthrough e efectiv activ, nu doar configurat.
- **ZFS**: `rpool` (RAID10, 4×960GB SSD, 1.54T liber) + `media` (RAIDZ2,
  6×SAS, 1.26T liber) — ambele `ONLINE`, 0 erori, scrub recent OK.
- **ARC**: 8GB confirmat activ.
- **VM-uri**: `windows11` (100, running), `home-assistant` (101, running),
  `ubuntu-server` (102, **stopped**), `kubernetes-controlplane-1` (800,
  running, 400GB pe `local-zfs`, `hostpci0: 0000:04:00` = GPU passthrough
  confirmat).
- **LXC**: `garage-r730xd` (103, running) — target Longhorn backup.
- **VM 800 migrarea pe `local-zfs`**: DONE (nu mai e pe `local-data`/dir).
- **NFS exports**: `/media/{library,backups,photos,isos}` + child datasets
  (`crossmnt` prezent, fix-ul din footgun-ul documentat e aplicat).
- **Network**: un singur `vmbr0` pe `nic3`, fără VLAN/trunk — rework-ul de
  VLAN pe partea R730xd **chiar nu e făcut** (confirmat live, nu doar din
  memorie).
- **Tailscale**: **inactiv** pe host (pachet neinstalat) — confirmat, tot
  nefăcut.
- **PBS**: nu există instanță server (nici LXC, nici VM) — doar
  `proxmox-backup-client`/`proxmox-backup-file-restore` instalate ca pachete,
  nefolosite direct de nimic vizibil.
- **Cron root** — 3 job-uri, doar 1 documentat:
  - `weekly-push-to-synology.sh` (Duminică 03:00) — documentat.
  - `zfs-snapshot-backups.sh` (zilnic 04:00) — **nedocumentat**. Snapshot ZFS
    zilnic pe `media/backups`, 14 zile retenție. Rulează și funcționează
    (snapshot-uri confirmate pe disc). Practic înlocuiește Sanoid (care era
    "pending" în plan) cu un script propriu — dar nimeni nu a scris asta
    nicăieri.
  - `restic-push-oracle.sh` (zilnic 04:15) — **nedocumentat și
    nemenționat nicăieri** în DR.md/README. Al doilea leg offsite spre
    Oracle, complet independent de releul săptămânal prin Synology: restic
    peste SFTP direct R730xd→Oracle, `--tag nightly`, retenție
    7 zilnic/4 săptămânal/3 lunar, cu `restic check` (verificare integritate)
    la final. Acoperă `oracle-vps/`, `immich-postgres/`, `dump/`,
    `pfsense/` — **dar NU** `longhorn-garage/` sau `synology-home/`, care
    rămân doar pe releul săptămânal.

### Beelink / px-0 (`10.57.57.254`) — Proxmox 9.2.4, kernel 7.0.14-4

- **VM-uri**: `datacenter-manager` (100, running — apliația Proxmox
  Datacenter Manager, leagă `pve`+`px-0`), `winserver` (102, **stopped**,
  52GB disk), `kubernetes-controlplane-2` (802, running),
  `kubernetes-controlplane-3` (804, running).
- **LXC**: `myspeed` (103, running) — test de viteză, fără legătură cu
  backup.
- **Storage**: `cluster-storage` = **un singur NVMe, fără redundanță**
  (nu e mirror/RAID) — găzduiește 2 din cele 3 noduri control-plane K8s
  (802 + 804, ~124G+40G folosiți). Dacă acest disk moare, pică simultan 2
  din 3 noduri de control-plane.
- **`synology-nas` definit ca storage Proxmox, dar `inactive`** (Synology e
  treaz doar duminică 02:50-03:40) — o definiție de storage care e
  funcțională ~50 min/săptămână, restul timpului `pvesm status` raportează
  eroare.
- **vzdump.cron: gol** — nicio VM de pe px-0 nu are backup automat (nici
  `datacenter-manager`, nici `winserver`). Pentru 802/804 e prin design (se
  recreează din DR), dar `winserver` stopped + nebackupat pare candidat de
  șters, nu de păstrat "ca să nu strice ceva".
- **Tailscale**: inactiv, la fel ca pe R730xd.

### Cluster Talos/K8s (acces direct via `kubectl` + `./kubeconfig`)

- 3 noduri `Ready`, versiuni aproape aliniate (cp1/cp2 Talos v1.13.4, cp3
  v1.13.6 — skew minor).
- **Toate volumele Longhorn: `healthy`, `attached`** — chiar acum clusterul
  de storage e sănătos. Instabilitatea simțită de tine e probabil despre
  frecvența incidentelor trecute, nu despre starea curentă.
- **2 HelmRelease-uri blocate (`Stalled`), chiar acum**:
  - **`immich-postgres` (ns `default`)** — upgrade eșuat **azi**
    (2026-07-25 ~07:00), Flux a dat rollback automat la v5 și s-a oprit din
    reîncercat (`RetriesExceeded`). Aplicația probabil merge (pe versiunea
    veche), dar orice schimbare făcută în Git pentru ea nu se va aplica
    până nu intervii manual.
  - **`csi-driver-nfs` (ns `kube-system`)** — blocat din **2026-07-23**
    (2 zile), motiv: un `StorageClass` (`nfs-slow`, spre
    `/volume1/Server/Kubernetes/Media` pe Synology) are un câmp imutabil
    (`parameters.share`) pe care upgrade-ul încearcă să-l schimbe. Flux
    a renunțat după 3 încercări — **de 2 zile, nimeni nu a fost anunțat**
    (fără alertă vizibilă pentru Stalled HelmReleases).
- **Drift confirmat GitOps vs. live**: `kubernetes/apps/storage/longhorn/app/namespace.yaml`
  din repo declară `pod-security.kubernetes.io/enforce: privileged` pentru
  `longhorn-system` — fix-ul aplicat manual în sesiunea de tshoot din
  20 iulie. **Namespace-ul live NU are eticheta asta** (doar `default` o
  are, corect). Kustomization-ul Flux `longhorn` e `Ready: True` și aplică
  fișierul, dar eticheta tot nu ajunge pe obiectul live — semn că
  race-condition-ul documentat atunci ("createNamespace vs Kustomization")
  nu a fost rezolvat la rădăcină, doar patch-uit manual o dată, și s-a
  întors. **Risc real**: dacă pod-urile Longhorn CSI repornesc curând, pot
  lovi exact același blocaj de PodSecurity ca în trecut.
- Cilium, cert-manager (toate certificatele `Ready`), Flux-operator/
  helm-controller/kustomize-controller — sănătoase, deși cu restart-uri
  recente (probabil auto-upgrade al operatorului, nu o problemă).

### Oracle VPS (`cloud`, Tailscale `100.72.22.38`, user `ubuntu`)

- **17 containere Docker rulează efectiv.** Comparat cu tabelul din
  README:
  - **`netdata` și `dozzle` sunt documentate în README dar NU rulează**
    (nici măcar oprite — nu există deloc în `docker ps -a`). README e
    stale pe aceste 2 rânduri.
  - Restul (Traefik, Pi-hole, Unbound, Authentik ×4, Portainer, Homepage,
    Joplin ×2, Guacamole, Garage ×2, Beszel, Glances, Code Server) rulează
    exact cum scrie.
- **Cron root — 5 job-uri, 4 documentate + 1 nedocumentat**:
  - `restore-drill.sh` (lunar, ziua 1, 04:00) — **nedocumentat nicăieri**.
    Script bine scris: pornește un Postgres temporar, importă cel mai
    recent dump Authentik/Joplin, verifică că are tabele, șterge totul —
    dovadă reală că backup-urile sunt restorabile, nu doar că `pg_dump` a
    ieșit cu cod 0. **Dar**: `HC_URL=""` — hook-ul de alertă (healthchecks.io)
    e gol, deci dacă drill-ul eșuează, **nimeni nu e anunțat**, doar apare
    în log. Și `/var/log/restore-drill.log` **nu există** — fie nu a rulat
    niciodată cu succes de când a fost adăugat, fie output-ul nu ajunge
    acolo. Nu poate fi confirmat că a rulat vreodată.
- **`mnt-nas.mount` — failed de 12 zile** (`10.57.57.201:/volume1/homes`,
  timeout) — unitate systemd orfană dintr-o etapă anterioară de migrare de
  pe Synology, nimeni n-a curățat-o.
- fail2ban: doar jail `sshd` (ok, minimal). `ufw` nici nu e instalat —
  filtrarea reală se bazează probabil pe Security List-urile Oracle Cloud,
  de verificat separat dacă vrei o imagine completă de firewall.

### pfSense (`10.57.57.1`) — acces SSH neașteptat, dar funcțional

- **VLAN 57 există deja** (pe `igb1`, subnet separat `10.57.97.0/24`,
  DHCP/DNS proprii) — independent de partea R730xd, care încă n-are
  bridge VLAN-aware. Nu e clar dacă VLAN 57 e folosit activ sau e
  jumătate dintr-un plan neterminat.
- **DNS pentru clienții LAN (DHCP) — ordinea e `1.1.1.1`, `8.8.8.8`,
  `10.57.57.111`** (`10.57.57.111` = IP-ul LoadBalancer al `k8s-gateway`
  din cluster, confirmat prin `kubectl get svc`). Pi-hole **nu e deloc în
  listă** — dispozitivele din LAN nu trec prin Pi-hole by default (doar
  dacă cineva își setează manual DNS-ul), iar rezoluția `*.merox.dev`
  internă depinde de faptul că un client anume ajunge să încerce al
  treilea server DNS din listă — comportament inconsecvent, dependent de
  stack-ul de rețea al fiecărui dispozitiv.
- **Tailscale rulează pe pfSense** (`merox-homelab`, FreeBSD, e motivul
  pentru care traficul Tailscale spre R730xd apare cu sursa `10.57.57.1` —
  confirmă exact footgun-ul documentat în `proxmox/r730xd/README.md`).
  Health check curent: **"Tailscale can't reach the configured DNS
  servers"** — un avertisment activ chiar acum.
- 48 de reguli de firewall — nu le-am analizat individual (volum mare,
  las pentru Faza 2 dacă vrei un audit de reguli specific).

---

## 2. Puncte de complexitate — cu impact

| # | Ce | Impact | Zonă |
|---|----|--------|------|
| 1 | Backup are **3 mecanisme independente** spre Oracle (Synology→HyperBackup săptămânal, restic direct zilnic, plus vzdump/pg_dump locale) — 2 din ele nedocumentate | Mental: nu știi ce rulează. Risc: politici de retenție diferite per categorie, fără logică unificată | Backup/Docs |
| 2 | `longhorn-system` namespace live nu are labelul PodSecurity declarat în repo | Risc real de recidivă a blocajului CSI documentat pe 20 iulie | Storage/GitOps |
| 3 | 2 HelmRelease-uri `Stalled` fără alertă vizibilă (immich-postgres de azi, csi-driver-nfs de 2 zile) | Operațional: schimbări din Git nu se aplică, silențios | Observabilitate/GitOps |
| 4 | `restore-drill.sh` are alertare dezactivată (`HC_URL=""`) și niciun log de execuție confirmată | Nu știi dacă backup-urile Authentik/Joplin sunt de fapt restorabile | Backup/Observabilitate |
| 5 | README documentează Netdata + Dozzle pe VPS — nu rulează deloc | Mental: documentația minte pe alocuri, nu doar e incompletă | Documentație |
| 6 | DNS LAN: Pi-hole absent din DHCP, `k8s-gateway` e ultimul din 3 servere | Rezoluție inconsistentă `*.merox.dev` + zero ad-blocking real pe LAN | DNS |
| 7 | `cluster-storage` pe px-0 = un singur NVMe fără redundanță, găzduiește 2/3 noduri control-plane | Un singur disk mort = 2 noduri control-plane pierdute simultan | Storage/Hardware |
| 8 | VM-uri orfane: `winserver` (px-0, stopped, nebackupat), `ubuntu-server` (R730xd, stopped) | Spațiu + suprafață mentală ocupate degeaba, dacă nu mai sunt necesare | Hypervisor |
| 9 | `mnt-nas.mount` failed de 12 zile pe VPS, `synology-nas` storage inactiv pe px-0 | Resturi de migrare necurățate, zgomot în `systemctl --failed` / `pvesm status` | Storage |
| 10 | VLAN 57 pe pfSense există independent de rework-ul R730xd | Neclar dacă sunt aceeași intenție sau două planuri paralele | Rețea |
| 11 | Observabilitate: Netdata(k8s) + Beszel(VPS) + Glances(VPS) + Prometheus/Grafana/Loki/AlertManager(k8s) | Nu există un singur loc unde te uiți când pică ceva | Observabilitate |

---

## 3. Backup — harta exactă mecanism ↔ date

Patru mecanisme, fiecare cu propria retenție, mișcând date parțial suprapuse.
Tabelul de mai jos e per **categorie de date** (nu per script), ca să se vadă
clar unde e redundanță reală și unde e o gaură.

| Categorie (sursă) | Longhorn→Garage (R730xd, ~02:00, retain 3) | ZFS snapshot local (`media/backups`, zilnic, 14 zile, doar pe R730xd — nu pleacă nicăieri) | Weekly push→Synology (Dum 03:00, 21 zile, versionat) | Synology→Oracle HyperBackup (Dum 03:20, 3 versiuni ~3 săpt) | restic direct R730xd→Oracle (zilnic 04:15, 7z/4săpt/3luni + check) | Copii care ajung **offsite la Oracle** |
|---|---|---|---|---|---|---|
| `oracle-vps/` (Authentik/Joplin dumps, vps-extras — vin de pe VPS nightly 03:30) | — | da | da | da | **da** | **2 căi independente** (HyperBackup + restic) |
| `immich-postgres/` (pg_dump, 30 zile retenție proprie) | — | da | da | da | **da** | **2 căi independente** |
| `dump/` (vzdump home-assistant, 02:30) | — | da | da | da | **da** | **2 căi independente** |
| `pfsense/` (config.xml.gz, 03:00) | — | da | da | da | **da** | **2 căi independente** |
| `longhorn-garage/` (Garage data+meta — ținta reală a backup-ului Longhorn) | da (local) | da | da | da | **NU** | **1 singură cale**, cadență săptămânală — dacă R730xd moare marți, copia de la Oracle poate fi veche de până la o săptămână |
| `synology-home/` (documente, sursă live acum, nu oglindă) | — | da | da | da | **NU** | **1 singură cale**, săptămânal |
| `/media/photos` (Immich uploads+external — **nu e în `/media/backups`**, dataset separat) | — | — | da | da | **NU** (nici măcar candidat — restic nu urcă `/media/photos`) | **1 singură cale**, săptămânal — cea mai puțin acoperită dată "pets" |
| `/media/library` (movies/tv/downloads) | — | — | — | — | — | **0 copii** — intenționat, "cattle" re-descărcabil |

**Cea mai mare redundanță**: `oracle-vps/`, `immich-postgres/`, `dump/`,
`pfsense/` ajung la Oracle **de două ori**, prin două unelte diferite
(HyperBackup propietar vs. restic verificat cu `check`) — dacă asta a fost
intenționat ca fallback unul-pentru-altul, măcar unul din cele două ar putea
fi redus la o cadență mai rară fără să pierzi protecție reală.

**Cea mai mare gaură**: exact datele "grele" — backup-ul Longhorn în sine
(`longhorn-garage/`), documentele (`synology-home/`) și pozele
(`/media/photos`) — au o **singură** cale spre offsite, și aceea e
săptămânală, nu zilnică. Restic-ul zilnic (mecanismul cel mai nou și cu
verificare de integritate reală via `restic check`) nu le atinge deloc.

**Retenții, ca reper** (variază mult, fără o logică unică):
Longhorn native: 3 copii · ZFS snapshot local: 14 zile · Synology: 21 zile ·
Synology→Oracle: ~3 săptămâni · restic→Oracle: 7 zilnic/4 săptămânal/3 lunar
(cel mai lung orizont, ~3 luni) · `/srv/backups` pe VPS (staging local
înainte de push): 7 zile · `immich-postgres` pg_dump pe R730xd: 30 zile.

---

## 4. Structura repo-ului (cerință specifică din misiune)

- **Flux**: instalat via `flux-operator` + `flux-instance` (pattern modern,
  nu `flux bootstrap` clasic) — o singură Kustomization de top
  (`cluster-apps`, path `./kubernetes/apps`, fără `kustomization.yaml`
  propriu — Flux descoperă recursiv toate manifestele) + `cluster-meta`
  pentru repo-urile Helm. Fiecare "aplicație" are propriul `ks.yaml`
  (Flux Kustomization) + `app/kustomization.yaml` (Kustomize nativ) — un
  pattern de 2 niveluri consistent peste tot.
- **Helm vs. manifeste brute**: 34 `helmrelease.yaml` vs. doar 2 manifeste
  brute (`portainer-agent/deployment.yaml`,
  `loki/.../statefulset-sidecar-tmpdir.yaml` — un patch, nu o aplicație
  întreagă). Practic 100% Helm — nu e un amestec dureros de întreținut.
- **Secrete**: SOPS/AGE, `.sops.yaml` cu 2 reguli clare (`talos/` cu MAC
  separat, `bootstrap|kubernetes` cu criptare doar pe `data`/`stringData`)
  — 16 fișiere criptate, nu e duplicat sau ad-hoc.
- **Renovate**: config amplu (Docker major, Flux, Helmfile, Kustomize,
  dashboard, automerge pe branch) — automatizarea de dependențe pare
  serioasă, nu de completat de la zero.

**Concluzie preliminară**: structura de bază a repo-ului (Flux + Kustomize +
Helm + SOPS) **nu pare supra-inginerită** — e consistentă și urmează un
pattern recunoscut în comunitate (vezi Faza 2 pentru comparație explicită).
Complexitatea reală nu e în "cum e organizat codul", ci în **operațiuni care
au evoluat pe lângă cod** (cron-uri adăugate manual, un al doilea leg de
backup, o etichetă care nu se aplică) — asta schimbă unde ar trebui să se
concentreze Faza 2/3: mai puțin "restructurează repo-ul", mai mult
"documentează ce există cu adevărat și repară drift-ul găsit".

---

## 5. Ce nu am putut audita direct

- **iDRAC (R730xd)** — necesită UI/racadm cu credențiale separate.
- **Cele 48 de reguli de firewall pfSense** — văzute doar ca număr, nu
  analizate individual.

Dacă vrei acoperire completă pe astea, spune-mi și îți dau comenzi
punctuale de rulat / ce să exporți din UI.

### Home Assistant — scos explicit din scope (decizie user, 2026-07-25)

VM 101 pe R730xd, `running`, backup vzdump nightly 02:30 — atât rămâne în
inventar, ca fapt. E "un VM cu care te joci ocazional", nu parte din
proiectul de simplificare. **Nu va apărea** cu recomandări, alternative sau
propuneri de schimbare în Faza 2 sau în planul din Faza 3, indiferent ce
iese din research pe alte layere adiacente (automatizare, identitate, etc.).

## 6. Presupuneri și ce ar fi îmbunătățit acest audit

- Am presupus că accesul SSH găsit din mers (R730xd, px-0, VPS cu userul
  `ubuntu`, pfSense cu userul `admin`) e OK de folosit read-only fără să
  întreb de fiecare dată — spune-mi dacă vrei să confirm explicit înainte
  de orice conectare viitoare la un host nou.
- Nu am analizat traficul/regulile de firewall în detaliu (pfSense, 48
  reguli) — las asta pentru Faza 2 dacă backup-ul/DNS-ul rămân prioritare.
- Nu știu dacă VLAN 57 (pfSense) e o intenție veche legată de rework-ul
  R730xd sau ceva complet separat — bun de clarificat înainte de Faza 3.
