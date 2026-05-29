# HEARTBEAT.md — Blog Agent

Runs once weekly: Monday 09:00 UTC (12:00 EEST).

## Purpose

Weekly pulse check: what happened in the last 7 days that could be worth a blog post?
This is a discovery run, not a drafting run. Output: a short Telegram note with 1-3 ideas (or nothing if nothing is worth it).

## Task order

1. Check `memory/` — what topics were already suggested in the last 4 weeks (don't repeat)
2. Read recent activity:
```bash
cd /srv/merox && git log --oneline --since="7 days ago" 2>/dev/null | head -10
ls -lt /srv/merox/src/content/blog/ 2>/dev/null | head -5
```
3. Check recent news from `/srv/dashboard/data/news.json` — any tech item Merox faced this week worth documenting?
4. Check infra changes: `cat /srv/dashboard/data/infra-extended.json 2>/dev/null`
5. Decide: is there 1 topic worth suggesting? If not → silence (don't send if nothing genuine)
6. Update `/srv/dashboard/data/agents.json`
7. Save to `memory/YYYY-MM-DD.md`

## Reporting rule

- **Good topic found** → send 1 short Telegram suggestion (max 3)
- **Nothing genuine** → print `HEARTBEAT_OK`, do NOT send Telegram
- Never force topics — a week with no ideas is fine

## Telegram (only when there's something real)

```python
import json, urllib.request, urllib.parse

config  = json.load(open('/home/openclaw/.openclaw/openclaw.json'))
TOKEN   = config['channels']['telegram']['botToken']
CHAT_ID = config['channels']['telegram']['allowFrom'][0]

msg = "✍️ *Blog pulse — " + data_azi + "*\n\n" + sugestii  # max 300 chars

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
✍️ *Blog pulse — 2 Iun 2026*

💡 *Talos + FluxCD upgrade workflow* — ai făcut upgrade la v1.13.3 săptămâna asta, procesul e non-obvious și lipsit din doc-uri. Potențial bun.
💡 *Self-hosted AI gateway cu OpenClaw* — ai setat un setup complex, puțini au documentat asta.
```

## Memory

Save to `memory/YYYY-MM-DD.md`:
- Topics suggested this week
- Topics rejected (and why — to avoid repeating)
