# HEARTBEAT.md — News Agent Morning Run

Triggered daily at 04:00 UTC via cron. Trigger message: `MORNING_RUN`.

## OBLIGATORIU: rulezi headless — folosești tools, nu text

**Răspunsul tău text merge într-un log, nu îl citește nimeni.**

- Telegram se trimite via Python urllib (cod mai jos) — NICIODATĂ ca response text
- Fișierele se scriu cu Write tool sau Bash+Python
- Dacă nu execuți tools, nu se întâmplă nimic

## Pași — execută în ordine

1. Citești `/srv/dashboard/data/news-releases.json` — GitHub releases pre-fetched de scriptul cron
2. Verifici `memory/` — ultimele 3 zile, nu repeți ce ai mai trimis
3. Colectezi știri tech & community din **surse multiple** (vezi mai jos)
4. **Scrii `/srv/dashboard/data/news.json`** — OBLIGATORIU PRIMUL, înainte de HTML (codul e mai jos). Acesta e ce afișează dashboard-ul principal la "Tech & Community". Fără el, coloana e goală.
5. Scrii `/srv/dashboard/news.html` — HTML dashboard complet
6. Trimiți Telegram via Python urllib
7. Actualizezi `/srv/dashboard/data/agents.json`
8. Salvezi în `memory/YYYY-MM-DD.md` ce ai trimis azi

## Surse — folosești toate, nu doar una

### Pre-fetched (citești direct)
- `/srv/dashboard/data/news-releases.json` — GitHub releases pentru stack-ul din AGENTS.md

### Fetch în timpul run-ului
- **Hacker News** — `https://hacker-news.firebaseio.com/v0/topstories.json` → top 50 IDs → fetch fiecare item. Max 5 items relevante conform filtrului din AGENTS.md.
- **Reddit r/homelab** — `https://www.reddit.com/r/homelab/top/.json?t=day&limit=10` — posturi tehnice cu substanță, nu "look at my setup"
- **Reddit r/selfhosted** — `https://www.reddit.com/r/selfhosted/top/.json?t=day&limit=10` — unelte noi cu tracțiune reală
- **Web search** (tool `web_search`) — caută CVE-uri noi, lansări AI, știri infra majore. Exemple: `"kubernetes CVE 2026"`, `"new open source LLM release"`, `site:github.com self-hosted new release`
- **GitHub trending** (opțional) — `https://github.com/trending?since=daily`

**Diversitate minimă**: news.json nu poate fi 100% HN. Target: GitHub releases + 2-3 HN + 1-2 Reddit + 1-2 din web search.

## Pasul 4 — Scrie news.json ACUM (înainte de orice altceva)

```python
import json, os, stat
from datetime import datetime, timezone

RO_MONTHS = ["Ian","Feb","Mar","Apr","Mai","Iun","Iul","Aug","Sep","Oct","Nov","Dec"]
now = datetime.now(timezone.utc)
today_ro = f"{now.day} {RO_MONTHS[now.month-1]} {now.year}"

# REGULA STRICTĂ PENTRU source:
# source = "GitHub"      → apare în coloana "Stack Updates"  (releases, CVE din stack)
# orice alt source       → apare în coloana "Tech & Community"
#
# Folosești "GitHub" DACĂ ȘI NUMAI DACĂ itemul vine din news-releases.json
# sau e un release/CVE dintr-un repo GitHub din stack-ul tău.
# NU folosi "Stack", "Kubernetes", "Security" etc. pentru release-uri GitHub — rupe dashboard-ul.
items = [
    {"title": "Talos v1.13.3 — ...", "url": "https://github.com/...", "source": "GitHub", "date": "1 Iun", "priority": "warn"},
    {"title": "CVE-2026-XXXX gRPC-Go — ...", "url": "https://...", "source": "Hacker News", "date": "1 Iun", "priority": "warn"},
    {"title": "Cloudflare Turnstile WebGL fingerprinting", "url": "https://...", "source": "Hacker News", "date": "1 Iun", "priority": "info"},
    {"title": "Immich v3.0.0 RC — ...", "url": "https://...", "source": "Reddit", "date": "1 Iun", "priority": "info"},
]

out = "/srv/dashboard/data/news.json"
with open(out, "w") as f:
    json.dump({"date": today_ro, "items": items}, f, indent=2, ensure_ascii=False)
os.chmod(out, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
```

Priorități:
- `"critical"` → CVE/breaking change pe **exact versiunea instalată**
- `"warn"` → update disponibil sau CVE cu impact neclar
- `"info"` → lansare nouă, știre community

## Trimitere Telegram (execuți codul, nu outputezi text)

```python
import json, urllib.request, urllib.parse
from datetime import datetime, timezone

config = json.load(open('/home/openclaw/.openclaw/openclaw.json'))
TOKEN  = config['channels']['telegram']['botToken']
CHAT_ID = config['channels']['telegram']['allowFrom'][0]

RO_MONTHS = ["Ian","Feb","Mar","Apr","Mai","Iun","Iul","Aug","Sep","Oct","Nov","Dec"]
now = datetime.now(timezone.utc)
data_azi = f"{now.day} {RO_MONTHS[now.month-1]} {now.year}"

# 3-5 bullets din cele mai importante items (critical > warn > info)
bullets = [
    "🔴 *Titlu* — context concret",
    "🟡 *Titlu* — context concret",
    "🟢 *Titlu* — context concret",
]

msg = f"📰 *Briefing {data_azi}*\n\n" + "\n".join(bullets) + "\n\nhttps://news.cloud.merox.dev"

payload = urllib.parse.urlencode({"chat_id": CHAT_ID, "text": msg, "parse_mode": "Markdown"}).encode()
req = urllib.request.Request(f"https://api.telegram.org/bot{TOKEN}/sendMessage", data=payload, method="POST")
with urllib.request.urlopen(req, timeout=10) as resp:
    result = json.load(resp)
    print(f"Telegram OK: message_id={result['result']['message_id']}")
```

Dacă nimic relevant: trimite `"📰 Stack liniștit azi — nimic critic de raportat."` + URL.

## Actualizare agents.json

```python
import json
from datetime import datetime, timezone

with open('/srv/dashboard/data/agents.json') as f:
    d = json.load(f)
d['news'] = {
    'lastRun': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'status': 'ok',
    'summary': 'REZUMAT_MAX_100_CHARS'
}
with open('/srv/dashboard/data/agents.json', 'w') as f:
    json.dump(d, f, indent=2)
```

## Format mesaj Telegram

```
📰 *Briefing 1 Iun 2026*

🔴 *Authentik 2026.5.2* — CVE patch, rulezi 2026.5.0 → upgrade necesar
🟡 *Talos v1.13.3* — disponibil, rulezi v1.13.0
🟢 *Claude Opus 4.8* — model nou Anthropic lansat azi
🟢 *r/homelab: Immich v3.0.0 RC* — workflows editor, HLS support

https://news.cloud.merox.dev
```
