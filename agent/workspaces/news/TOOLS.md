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
