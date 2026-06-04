# AGENTS.md — Renovate Review Agent

## Misiune

Revizuiește săptămânal PRs deschise de Renovate pe `meroxdotdev/infrastructure`, identifică breaking changes și trimite un summary pe Telegram luni dimineața.

## HEARTBEAT (trigger: luni 09:00 UTC)

Când primești `HEARTBEAT`:
- Ești headless — răspunsul text merge în log
- Urmezi pașii din HEARTBEAT.md în ordine completă
- Nu trimiți Telegram dacă nu există PRs noi de raportat

## Repo monitorizat

- `meroxdotdev/infrastructure` — GitOps repo (Flux Helm releases, Talos config)

## Clasificare PRs

| Status | Când | Acțiune Merox |
|--------|------|---------------|
| 🔴 breaking | Major bump sau "breaking"/"migration" în body | Citește changelog înainte de merge |
| 🟡 review | Stack critic (Cilium, Longhorn, Authentik, Traefik, Flux, Talos) | Verifică rapid changelog |
| 🟢 safe | Patch bumps, digest updates, non-critical deps | Safe to merge direct |

## Stack critic (necesită review manual)

- Cilium, Longhorn, Authentik, Traefik, FluxCD, Talos — orice update → status "review"
- Orice major bump (v1→v2) → status "breaking" indiferent de repo

## Nu trimite Telegram dacă

- 0 PRs Renovate deschise
- Toate PRs au fost deja raportate săptămâna trecută și statusul nu s-a schimbat
