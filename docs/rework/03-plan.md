# Faza 3 — Plan de execuție

Pe baza verdictelor din `02-research.md`. Ordonat după raport câștig/efort —
cele cu impact mare și risc mic primele. **R730xd (VLAN, Tailscale, PBS)
rămâne explicit separat**, nu intră în acest plan (decizie confirmată).
Nimic din pașii de mai jos e executat — planul așteaptă aprobare.

## Tabel sumar

| # | Pas | Simplifică | Risc | Durată | Cine |
|---|---|---|---|---|---|
| 1 | ✅ Alertare reală — Discord (Alertmanager + Flux notification-controller nativ) | Elimină cel mai mare gol găsit — niciun incident nu ajungea la un om, doar heartbeat | Minim — verificat cu alertă de test, livrat | Făcut | Mecanic |
| 2 | ⛔ Sărit — Pi-hole/DNS local (pfSense) | N/A | N/A | N/A | Nu era o problemă reală — `media.merox.dev` acoperă deja nevoia practică pentru LAN fără Tailscale; inconsecvența DNS găsită în audit (Unbound activ dar nefolosit de DHCP) rămâne, dar userul confirmă că nimeni n-o simte în practică |
| 3 | ✅ Scoate Glances de pe VPS | Făcut — o unealtă mai puțin, Beszel acoperă deja rolul | Container orfan curățat, `remove_orphans` adăugat pt viitor | Făcut | Mecanic |
| — | ✅ (nepланificat) Elimină `cloudlab-merox` ca repo separat | Bug real găsit: Ansible-ul din `infrastructure` era suprascris silențios de clona `cloudlab-merox` pentru garage/guacamole/traefik/netdata la fiecare `make setup` | Servicii live externe atinse — testat cu `--check --diff` întâi, apoi rulare reală, verificat container cu container | Făcut | Repo migrat, vechi arhivat pe GitHub |
| 4 | ✅ Fix namespace collision la `portainer-agent` | **Fals-pozitiv** — verificat live, nu are de fapt problema de la Longhorn (Kustomization-ul propriu trăiește în `default`, nu în `portainer`, deci fără cursă de field-ownership) | N/A | Verificat, nimic de reparat | — |
| 5 | ✅ Audit sistematic pt alte coliziuni namespace în tot repo-ul | Rezultat curat: `portainer-agent` e singura aplicație cu `namespace.yaml` propriu rămasă în tot repo-ul, și e deja confirmată sigură. Longhorn a fost singurul caz real | Zero — doar citire | Făcut | Verificare |
| 6 | ✅ Extinde `restic-push-oracle.sh` peste golurile găsite (`longhorn-garage/`, `synology-home/`, `/media/photos`) | Acoperă exact datele critice care aveau o singură cale offsite, săptămânală. Exclus explicit `dump/` (Home Assistant, ~14GB/noapte — în afara scope-ului proiectului, cerut de user) | Testat cu 2 rulări reale + `restic check` curat de ambele ori + **test real de restaurare** (checksum verificat, nu presupus) înainte de tăiere | Făcut, azi | Hibrid — decizie de scop + implementare |
| 7 | ✅ Elimină leg-ul HyperBackup Synology→Oracle | Din 4 mecanisme de backup, rămân 2 curate: Synology (copie locală rapidă săptămânală) + restic (offsite zilnic, fără dependență DSM, pt tot) | Redus prin verificare, nu presupunere — vezi Pas 6. `rsyncd` (daemon + config) eliminat de pe VPS, nemaifiind destinația niciunui task | Făcut, azi | Decizie + implementare |

## Note per pas

**Pas 1 — Alertare (făcut)**: nu Pushover (cost) — Discord, refolosind
webhook-ul deja existent pentru alertele Netdata. Două piese: Alertmanager→
Discord (`discordConfigs` nativ, pt alerte Prometheus severity:critical) +
Flux notification-controller→Discord direct (Provider/Alert CRD-uri, deja
rulând, nefolosite până acum) pentru eșecuri Kustomization/HelmRelease —
`gotk_reconcile_condition` (metrica din rețetele clasice de PrometheusRule)
nu există în această versiune de Flux, deci calea Prometheus nu era
viabilă pentru asta oricum. Găsit și curățat incidental: 3 PDB-uri orfane
Longhorn care ar fi spamat noua alertare.

**Pas 2 — sărit**: Unbound rulează pe pfSense (pfBlockerNG activ), dar DHCP
tot dă LAN-ului `1.1.1.1`/`8.8.8.8` direct, nu IP-ul pfSense — deci
ad-blocking-ul local stă nefolosit și `k8s.merox.dev` nu rezolvă din LAN
simplu. Rămâne o inconsecvență reală, dar userul confirmă că nu-l afectează
în practică (`media.merox.dev` funcționează deja pentru LAN fără Tailscale).
Nu s-a atins nimic pe pfSense.

**Pas 3 (nepланificat)**: în timp ce scoteam Glances, a ieșit la iveală că
fișierul lui trăiește în `cloudlab-merox`, un repo separat pe care Ansible-ul
din `infrastructure` îl clona și suprascria peste propriile temple pentru
garage/guacamole/traefik/netdata — un bug real de suprascriere silențioasă,
nu doar "prea multe repo-uri". Migrat complet: fișierele statice acum în
`vps/roles/app_stack_setup/files/`, rolul rescris să facă `copy` în loc de
`git clone`, testat cu `--check --diff` + rulare reală, toate containerele
verificate sănătoase. `cloudlab-merox` arhivat pe GitHub (nu șters).

**Pas 4-5**: criteriul exact pentru risc real (nu doar aparență similară):
Kustomization-ul Flux al aplicației trebuie să trăiască *în interiorul*
namespace-ului pe care-l gestionează (ca Longhorn), nu într-un namespace
neutru ca `default`. Verificat live: `portainer-agent` nu îndeplinește
condiția asta, deci n-are cursa de field-ownership — fals-pozitiv. Auditul
sistematic (grep pe toate `namespace.yaml` din `app/`) confirmă că nu mai
există alte cazuri.

**Pas 6-7 (făcut, într-o singură sesiune, nu într-o lună cum era planul
inițial)**: recalibrat pe parcurs cu principiul "nu supra-inginerim" —
`/media/photos` și config-urile *arr aveau deja RAID/PVC replicat, deci
`synology-home/` (documente) era singura categorie fără o a doua protecție
reală. De-acolo a ieșit întrebarea mai mare: de ce să ținem HyperBackup
(dependent de DSM) dacă restic (fără nicio dependență) poate acoperi totul?
Răspuns: nu are sens, dar nu s-a tăiat orbește — s-a extins scope-ul
restic-ului, verificat cu 2 rulări reale + `restic check` + **un test real
de restaurare cu checksum** (nu doar "push-ul a mers"), abia apoi eliminat
HyperBackup + `rsyncd`-ul care-i servea drept destinație pe VPS. Exclus
explicit `dump/` (Home Assistant) din tot mesh-ul de offsite — în afara
scope-ului, cerut de user în timp ce se lucra la asta.

## Ce rămâne în afara acestui plan

- **R730xd** (VLAN, Tailscale pe host, PBS) — separat, cum s-a decis.
- Schimbări de arhitectură din `onedr0p/cluster-template` (envoy-gateway,
  config TOML, `justfile`, bootstrap Flux mai granular) — notate ca opțiuni
  în `02-research.md`, nu task-uri; de reluat într-o sesiune dedicată dacă
  devine interesant.

## Presupuneri

- Pasul 1 (cine face) e lăsat deschis intenționat — nu se presupune că
  "azi nu vreau să învăț" (valabil pentru immich-postgres) se extinde la
  toate sesiunile viitoare.
- Ordinea de mai sus e după impact/risc, nu obligatorie — pașii sunt
  independenți între ei (cu excepția 6→7), pot fi luați în orice ordine.
