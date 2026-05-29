# HEARTBEAT.md — Costs & Backup Agent

Runs once weekly: Sunday 09:00 UTC (12:00 EEST).

## Task order

1. TLS cert check (Mission 0 from AGENTS.md) — always first, alert if < 14 days
2. Backup verification (Mission 1 from AGENTS.md)
3. Write `/srv/dashboard/data/backup.json` with results
4. Update `/srv/dashboard/data/agents.json`
5. Save summary to `memory/YYYY-MM-DD.md`
6. Send Telegram report (see rule below)

## Reporting rule

- **All OK** → send a short weekly summary to Telegram
- **Warning** (backup > 7 days, cert < 30 days) → include in summary with ⚠️
- **Critical** (cert < 14 days, no backup, disk > 85%) → send immediately with 🔴

## Telegram (direct API — nu response text)

```python
import json, urllib.request, urllib.parse

config  = json.load(open('/home/openclaw/.openclaw/openclaw.json'))
TOKEN   = config['channels']['telegram']['botToken']
CHAT_ID = config['channels']['telegram']['allowFrom'][0]

msg = "💰 *Costs & Backup — " + data_azi + "*\n\n" + continut  # max 400 chars

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

## Format mesaj Telegram

```
💰 *Costs & Backup — 1 Iun 2026*

🟢 Certs: merox.dev 45 zile, cloud 60 zile
🟢 Longhorn: backup ieri (ok)
⚠️ Joplin DB: ultimul backup acum 8 zile
🟢 Disk VPS: 62%
```

## Memory

Save to `memory/YYYY-MM-DD.md`:
- What was checked
- Which services have backups and when
- Any warnings found
