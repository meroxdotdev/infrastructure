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
| 6 | Extinde `restic-push-oracle.sh` peste golurile găsite (`longhorn-garage/`, `synology-home/`, `/media/photos`) | Acoperă exact datele critice care azi au o singură cale offsite, săptămânală | Mediu — script de producție pe date reale; testare manuală + `restic check` înainte de cron | 1-2h | Hibrid — decizie de scop/retenție + implementare |
| 7 | Evaluează reducerea leg-ului săptămânal Synology pentru categoriile acum dublu-acoperite | Elimină redundanța reală (`oracle-vps/`, `immich-postgres/`, `dump/`, `pfsense/` ajung de 2 ori la Oracle) | **Nu înainte de pasul 6 verificat funcțional măcar o lună** — altfel dispare fallback-ul fără unul nou dovedit | Mică, o linie de config, după decizie | Decizie + implementare mică |

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

**Pas 6-7**: schimbare pe mecanismul de backup activ — nu se grăbește. Pasul
7 depinde explicit de pasul 6 fiind rulat și verificat o perioadă, nu doar
scris.

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
