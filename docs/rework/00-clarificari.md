# Faza 0 — Clarificări

Document permanent al fazei de clarificare pentru proiectul de simplificare
homelab + cloud. Vezi și `01-inventar.md` (Faza 1) pentru continuare.

## Ce am aflat înainte de a întreba (audit read-only rapid al repo-ului)

Repo-ul `meroxdotdev/infrastructure` are deja o structură neașteptat de matură:

- `README.md` — single-reference doc cu tot ce rulează, unde e codul, unde
  sunt secretele.
- `DEPLOY.md` (486 linii) + `DR.md` (281 linii, testat end-to-end
  2026-06-06, ~35 min) — runbook-uri concrete, nu ficțiune goală.
- Secrete: SOPS/AGE pentru k8s, Ansible Vault pentru VPS — consistent, nu
  duplicat la prima vedere.
- Backup: nu e "shotgun" cum pare din exterior — e un mesh deliberat,
  reconfigurat recent (cutover Garage VPS→R730xd 2026-07-21, decomisionare
  Synology 2026-07-22/23, leg Oracle 2026-07-23), fiecare decizie explicată
  în `proxmox/r730xd/README.md` și `vps/roles/vps_backup/README.md`.
  Problema reală nu pare să fie "prost gândit", ci **prea multe mecanisme
  diferite** (Longhorn native backup, vzdump, pg_dump, rsync+cron custom,
  DSM Hyper Backup) documentate în **6 fișiere separate** care se referă
  unul la altul — de-asta senzația că nu mai știi ce documentație există.
  Candidat puternic pentru Faza 2 (consolidare mecanisme + un singur loc
  canonic), nu doar impresie subiectivă.
- R730xd rework: exista o notiță de memorie (dintr-o sesiune anterioară)
  despre stadiul lui (reboot pending, migrare VM 800, PBS, VLAN-uri, VM 802).
  **Userul a confirmat explicit că acea notiță nu mai e la zi.** Tratată ca
  neactualizată; Faza 1 stabilește starea reală prin SSH, fără să pornească
  de la acea notiță.

## Întrebări puse și răspunsuri primite

**1. Ce te enervează cel mai des în practică, în ultima vreme?**
Unelte de monitorizare suprapuse (Netdata, Beszel, Glances, Dozzle,
Prometheus/Grafana), Longhorn/storage instabil, R730xd rework neterminat,
plus backup-ul perceput ca prea complex/fără o arhitectură 3-2-1 clară și
documentație greu de urmărit.

**2. Cât downtime tolerezi și pe ce servicii?**
Nu contează dacă pică din cauza curentului — R730xd și Beelink sunt
gestionate prin Proxmox Datacenter Manager, VPS-ul e Oracle Cloud — se
recuperează singure. Nu vrea tiers stricte per serviciu.

**3. Cât timp/săptămână pentru mentenanță, după simplificare?**
2-4h/săptămână.

**4. Ce vrei să înveți hands-on vs. ce vrei doar să funcționeze?**
GitOps/k8s (Flux, Kustomize, secrete) și networking/DNS/VPN — dar **după**
ce infrastructura e stabilă/curată. Învățarea hands-on vine ca pas separat,
posibil pe un cluster "dev", nu acum.

**5. R730xd rework — parte din scope-ul simplificării, sau proiect separat?**
Netranșat explicit de user — a corectat doar faptul că memoria mea despre
stadiul rework-ului e învechită. Tratat ca "de stabilit după ce vedem
starea reală în Faza 1", nu se presupune nimic acum.

**6. Backup 3-2-1 — ai o arhitectură în minte?**
Nu una fixă — userul a cerut explicit să citesc documentația din repo întâi
ca să înțeleg cum arată acum, înainte să se propună o restructurare.
Concluzia preliminară e mai sus (prea multe mecanisme, nu prost gândit);
propunerea concretă de restructurare rămâne pentru Faza 2.

**7. Acces pentru auditul din Faza 1?**
SSH direct unde există acces (R730xd, Beelink/px-0, noduri Talos, Oracle
VPS — confirmat: `10.57.57.250` răspunde la ping, există config SSH local
pentru câteva hosturi). Pentru iDRAC/BIOS, UI pfSense, Home Assistant:
comenzi punctuale date userului, care trimite output-ul înapoi.

## Presupuneri făcute (de verificat/corectat de user)

- "R730xd rework" și "proiectul de simplificare" rămân formal un singur fir
  de lucru în `docs/rework/`, urmând să se decidă abia după Faza 1 dacă
  task-urile R730xd neterminate intră în Faza 3 timpuriu sau rămân separate.
- Backup-ul, deși complex, e o zonă de **consolidare** (mai puține mecanisme/
  fișiere), nu de înlocuire completă — pentru că ce există funcționează și e
  parțial testat (DR general da; leg-ul total-loss R730xd/Synology gone nu e
  încă "drilled" conform `DR.md`).
- "Absolut tot, 14 layere" rămâne scopul Fazei 1, dar cu mai mult
  timp/detaliu pe: storage/Longhorn, observabilitate, backup, documentație,
  hardware/hypervisor R730xd — punctele confirmate explicit de user ca
  reale, nu doar teoretice.

## Decizii de scop ulterioare (după Faza 1, 2026-07-25)

- **Home Assistant — scos explicit din scope.** VM 101 (R730xd) e "un VM cu
  care te joci ocazional" — rămâne doar ca fapt în `01-inventar.md`
  (rulează, backup vzdump nightly), fără nicio recomandare/simplificare/
  schimbare în Faza 2 sau planul din Faza 3.

## Ce informație ar fi îmbunătățit acest rezultat

- O confirmare explicită dacă task-urile R730xd neterminate trebuie
  "înghețate" până se termină Faza 1/2, sau tratate ca urgențe separate de
  rezolvat oricum, independent de simplificare.
- Acces citit (nu neapărat SSH) la iDRAC/pfSense/Home Assistant ar elimina
  pasul manual de "rulează tu comanda și dă-mi output-ul" pentru acele 3
  bucăți.
