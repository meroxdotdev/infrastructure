# HEARTBEAT.md — Renovate Review Agent

Rulează **sâmbătă la 10:00 UTC** (13:00 EEST). Trigger message: `HEARTBEAT`.

## OBLIGATORIU: rulezi headless — folosești tools, nu text

Răspunsul text merge într-un log. TOATE acțiunile se fac via tools/Python.

## Pași — execută în ordine

### 1. Fetch PRs Renovate deschise

```python
import urllib.request, json

REPO = "meroxdotdev/infrastructure"
url = f"https://api.github.com/repos/{REPO}/pulls?state=open&per_page=50"
headers = {"Accept": "application/vnd.github+json", "User-Agent": "openclaw-renovate-agent"}

req = urllib.request.Request(url, headers=headers)
with urllib.request.urlopen(req, timeout=15) as resp:
    prs = json.load(resp)

renovate_prs = [pr for pr in prs if pr.get("user", {}).get("login") == "renovate[bot]"]
print(f"Found {len(renovate_prs)} Renovate PRs")
```

### 2. Dacă 0 PRs → skip Telegram, doar actualizezi agents.json

```python
# status = "ok", summary = "0 Renovate PRs open"
# NU trimite Telegram dacă nu există PRs
```

### 3. Verifici memory/ — nu repeți PR-uri din săptămâna trecută

Citești `memory/YYYY-MM-DD.md` din ultimele 7 zile. Dacă un PR URL apare deja, îl marchezi ca "already reported" și îl omit din mesaj (dacă nu s-a schimbat statusul).

### 4. Analizezi fiecare PR

Pentru fiecare `pr` în `renovate_prs`:

```python
title  = pr["title"]    # ex: "chore(deps): update helm release authentik to v2026.5.2"
url    = pr["html_url"]
body   = pr["body"] or ""
labels = [l["name"] for l in pr.get("labels", [])]

# Detectare tip update din titlu
import re
# Major bump: "v1.x → v2.x" sau "1.x.x to 2.x.x"
# Caută în body: "breaking", "BREAKING CHANGE", "migration", "removed", "incompatible"
has_breaking = any(kw in body.lower() for kw in ["breaking", "migration guide", "incompatible", "removed in"])

# Clasificare
if has_breaking or re.search(r'to v?\d+\.', title) and "major" in labels:
    status = "breaking"
elif any(c in title for c in ["authentik", "cilium", "longhorn", "talos", "traefik", "flux"]):
    status = "review"   # stack critic — verifică manual
else:
    status = "safe"
```

### 5. Scrii renovate.json

Vezi TOOLS.md pentru cod complet.

### 6. Construiești mesajul Telegram

```
🔧 *Renovate — meroxdotdev/infrastructure*
*Săptămâna {data}* — {N} PR-uri deschise

🔴 *Breaking* (1):
• [update helm release flux2 to v2.5.0](url) — major bump, migration guide prezent

🟡 *De verificat* (2):
• [update helm release authentik to v2026.5.2](url) — stack critic, patch release
• [update helm release cilium to v1.17.3](url) — networking, verifică changelog

🟢 *Safe to merge* (5):
• update docker digest pentru 5 imagini — patch updates, no breaking changes

📋 Toate PRs: https://github.com/meroxdotdev/infrastructure/pulls
```

**Reguli mesaj:**
- Grupează patch-urile de digest/imagini într-un singur bullet cu număr
- Nu lista mai mult de 3 items per categorie — rest = "și alte X"
- Dacă totul e safe: `"✅ N PRs — toate safe to merge, nicio acțiune necesară."`
- Link-urile Markdown funcționează în Telegram cu parse_mode=Markdown

### 7. Trimiți pe Telegram

Vezi TOOLS.md pentru cod complet.

### 8. Actualizezi agents.json

```python
# status = "ok" dacă ai procesat fără erori
# status = "warn" dacă există PRs cu breaking changes (necesită atenție)
# summary ex: "5 PRs: 1 breaking, 2 review, 2 safe"
```

### 9. Salvezi în memory/

```python
from datetime import datetime, timezone
today = datetime.now(timezone.utc).strftime('%Y-%m-%d')

content = f"# Renovate Run {today}\n\n"
content += f"PRs analizate: {len(renovate_prs)}\n\n"
for pr in renovate_prs:
    content += f"- [{pr['title']}]({pr['html_url']}) — {pr_status}\n"

with open(f"/home/openclaw/.openclaw/workspace-renovate/memory/{today}.md", "w") as f:
    f.write(content)
```
