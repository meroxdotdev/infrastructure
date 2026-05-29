# TOOLS.md — News Agent

## Dashboard paths

- News HTML: `/srv/dashboard/news.html`
- News data: `/srv/dashboard/data/news.json`
- Agents status: `/srv/dashboard/data/agents.json`
- Dashboard URL: `https://news.cloud.merox.dev` (also: `https://agents.cloud.merox.dev`)

## GitHub repos to monitor

- `meroxdotdev/merox` — personal site
- `meroxdotdev/infrastructure` — homelab infrastructure
- `siderolabs/talos` — Talos OS
- `fluxcd/flux2` — FluxCD
- `longhorn/longhorn` — Longhorn storage
- `cilium/cilium` — Cilium networking
- `goauthentik/authentik` — Authentik
- `traefik/traefik` — Traefik

## Updating dashboard data

After each run, update agent status:
```python
import json
from datetime import datetime
with open('/srv/dashboard/data/agents.json') as f:
    d = json.load(f)
d['news'] = {
    'lastRun': datetime.utcnow().isoformat() + 'Z',
    'status': 'ok',  # ok / warn / error
    'summary': 'SHORT_SUMMARY_MAX_100_CHARS'
}
with open('/srv/dashboard/data/agents.json', 'w') as f:
    json.dump(d, f, indent=2)
```

Write news data:
```python
import json
news_data = {
    "date": "28 May 2026",
    "items": [
        {"title": "Title", "url": "https://...", "source": "GitHub", "date": "28 May", "priority": "critical"},
        {"title": "Another", "url": None, "source": "community", "date": "28 May", "priority": "info"}
    ]
}
with open('/srv/dashboard/data/news.json', 'w') as f:
    json.dump(news_data, f, indent=2)
```

## Priority levels in news.json

- `"critical"` → 🔴 security fix or breaking change
- `"warn"` → 🟡 important update
- `"info"` → 🟢 informational

---

## System overview — all agents + crons

You are the default entry point for all Telegram messages. When Merox asks about any agent, check here first.

### Agent schedule (openclaw user crontab)

| Agent | Cron (UTC) | Log | Owned data |
|-------|-----------|-----|-----------|
| `news` (you) | `0 7 * * *` daily | `heartbeat-news.log` | `news.json`, `news.html` |
| `infra` | `0 8,20 * * *` 2×/day | `heartbeat-infra.log` | `infra-extended.json`, `agents.json[infra]` |
| `costs` | `0 9 * * 0` Sunday | `heartbeat-costs.log` | `backup.json`, `agents.json[costs]` |
| `dashboard` | `0 23 * * *` nightly | `heartbeat-dashboard.log` | `index.html`, `agents.json[dashboard]` |
| `orchestrator` | `0 12 * * *` daily | `heartbeat-orchestrator.log` | `orchestrator.json`, `proposals.json` |
| `blog` | `0 9 * * 1` Monday | `heartbeat-blog.log` | `/srv/merox/src/content/blog/` |
| `design` | on-demand only | — | — |

### Bash scripts (zero AI tokens — cron every 5/30/360 min)

| Script | Cron | Output |
|--------|------|--------|
| `update-infra.sh` | `*/5 * * * *` | `infra.json` ← **OWNED BY BASH, never write this** |
| `update-backup.sh` | `*/30 * * * *` | partial `backup.json` update |
| `update-news.sh` | `0 */6 * * *` | GitHub releases pre-fetch |

### Check if an agent ran recently

```bash
python3 -c "import json; d=json.load(open('/srv/dashboard/data/agents.json')); [print(k, d[k].get('lastRun','?'), d[k].get('status','?')) for k in d]"
```

### Check agent logs

```bash
tail -20 /home/openclaw/.openclaw/logs/heartbeat-infra.log
tail -20 /home/openclaw/.openclaw/logs/heartbeat-news.log
# etc.
```

### Command delegation (when Merox sends /approve, /infra, etc.)

See "Command routing" section in AGENTS.md.
