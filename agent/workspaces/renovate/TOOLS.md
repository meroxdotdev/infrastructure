# TOOLS.md — Renovate Agent

## GitHub API — fetch PRs Renovate

```python
import urllib.request, json

REPO = "meroxdotdev/infrastructure"
GITHUB_TOKEN = ""  # citit din openclaw.json dacă configurat, altfel fără auth (rate limit 60/h)

url = f"https://api.github.com/repos/{REPO}/pulls?state=open&per_page=50"
headers = {"Accept": "application/vnd.github+json", "User-Agent": "openclaw-renovate-agent"}
if GITHUB_TOKEN:
    headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"

req = urllib.request.Request(url, headers=headers)
with urllib.request.urlopen(req, timeout=15) as resp:
    prs = json.load(resp)

renovate_prs = [pr for pr in prs if pr.get("user", {}).get("login") == "renovate[bot]"]
```

## GitHub API — fetch PR labels și body

```python
# Din PR object ai deja: pr["title"], pr["html_url"], pr["body"], pr["labels"]
# Labels utile: "automerge", "dependency", "security"
# Body conține de obicei changelog sau link la release notes

for pr in renovate_prs:
    title = pr["title"]       # ex: "chore(deps): update helm release authentik to v2026.5.2"
    url   = pr["html_url"]
    body  = pr["body"] or ""  # poate conține release notes inline
    labels = [l["name"] for l in pr.get("labels", [])]
```

## GitHub API — fetch release notes pentru o versiune

```python
# Dacă vrei să verifici changelog-ul versiunii noi
# Extrage repo-ul și tag-ul din titlul PR-ului
# ex: "update helm release authentik to v2026.5.2" → repo goauthentik/authentik, tag v2026.5.2

release_url = f"https://api.github.com/repos/{upstream_repo}/releases/tags/{tag}"
req = urllib.request.Request(release_url, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        release = json.load(resp)
        notes = release.get("body", "")
except urllib.error.HTTPError:
    notes = ""  # release nu există sau e privat
```

## Cum identifici breaking changes

Caută în body-ul PR-ului sau release notes:
- Cuvinte cheie: "breaking", "BREAKING CHANGE", "migration", "deprecated", "removed", "incompatible"
- Major version bump (v1.x → v2.x) = risc ridicat, verifică manual
- Minor bump (v1.1 → v1.2) = verifică dacă e în stack critic (Talos, Cilium, Longhorn)
- Patch bump (v1.1.0 → v1.1.1) = safe în general, grupează în mesaj

## Dashboard paths

- Agents status: `/srv/dashboard/data/agents.json` — scrii doar cheia `renovate`
- Renovate data: `/srv/dashboard/data/renovate.json` — scrii tu după fiecare run

## Salvare renovate.json

```python
import json, os, stat
from datetime import datetime, timezone

RO_MONTHS = ["Ian","Feb","Mar","Apr","Mai","Iun","Iul","Aug","Sep","Oct","Nov","Dec"]
now = datetime.now(timezone.utc)
today_ro = f"{now.day} {RO_MONTHS[now.month-1]} {now.year}"

data = {
    "date": today_ro,
    "repo": "meroxdotdev/infrastructure",
    "prs": [
        {
            "title": "chore(deps): update helm release authentik to v2026.5.2",
            "url": "https://github.com/meroxdotdev/infrastructure/pull/42",
            "status": "safe",      # "safe" | "review" | "breaking"
            "note": "patch release, no breaking changes"
        }
    ],
    "summary": "3 safe, 1 needs review"
}

out = "/srv/dashboard/data/renovate.json"
with open(out, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.chmod(out, 0o644)
```

## Actualizare agents.json

```python
import json
from datetime import datetime, timezone

with open('/srv/dashboard/data/agents.json') as f:
    d = json.load(f)

d['renovate'] = {
    'lastRun': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'status': 'ok',   # ok / warn / error
    'summary': 'REZUMAT_MAX_100_CHARS'
}

with open('/srv/dashboard/data/agents.json', 'w') as f:
    json.dump(d, f, indent=2)
```

## Trimitere Telegram

```python
import json, urllib.request, urllib.parse

config  = json.load(open('/home/openclaw/.openclaw/openclaw.json'))
TOKEN   = config['channels']['telegram']['botToken']
CHAT_ID = config['channels']['telegram']['allowFrom'][0]

msg = "🔧 *Renovate — meroxdotdev/infrastructure*\n\n" + body_mesaj

data = urllib.parse.urlencode({
    "chat_id":    CHAT_ID,
    "text":       msg,
    "parse_mode": "Markdown"
}).encode()

req = urllib.request.Request(
    f"https://api.telegram.org/bot{TOKEN}/sendMessage",
    data=data, method="POST"
)
with urllib.request.urlopen(req, timeout=10) as resp:
    result = json.load(resp)
    print(f"Telegram OK: message_id={result['result']['message_id']}")
```
