# TOOLS.md — Orchestrator Agent

## Paths

### Read (never write directly)
- `/srv/dashboard/data/agents.json` — all agents' last run status
- `/srv/dashboard/data/news.json` — last news briefing
- `/srv/dashboard/data/infra.json` — live infra state
- `/home/openclaw/.openclaw/logs/heartbeat-*.log` — agent logs
- `/home/openclaw/.openclaw/workspace*/memory/*.md` — agent memory files
- `/home/openclaw/.openclaw/workspace*/AGENTS.md` — agent instruction files (read for proposals)

### Own (read + write)
- `/srv/dashboard/data/orchestrator.json` — own run history + last agents snapshot
- `/srv/dashboard/data/proposals.json` — improvement proposals
- `/home/openclaw/.openclaw/workspace-orchestrator/memory/` — own memory

### Backup convention
Before modifying any external file: copy to `<original-path>.<YYYYMMDDHHmmss>.bak`
Backups are never deleted automatically — only if disk > 90%.

## Full cron schedule (openclaw user)

| Agent | Cron (UTC) | Log file |
|-------|-----------|----------|
| `news` | `0 7 * * *` daily | `heartbeat-news.log` |
| `infra` | `0 8 * * *` + `0 20 * * *` | `heartbeat-infra.log` |
| `costs` | `0 9 * * 0` Sunday | `heartbeat-costs.log` |
| `dashboard` | `0 23 * * *` nightly | `heartbeat-dashboard.log` |
| `orchestrator` (you) | `0 12 * * *` daily | `heartbeat-orchestrator.log` |
| `blog` | `0 9 * * 1` Monday | `heartbeat-blog.log` |
| `update-infra.sh` (bash) | `*/5 * * * *` | `update-infra.log` |
| `update-backup.sh` (bash) | `*/30 * * * *` | (no separate log) |
| `update-news.sh` (bash) | `0 */6 * * *` | `update-news.log` |

All logs at: `/home/openclaw/.openclaw/logs/`

Expected max age per agent (hours before flagging as stale):
- news: 25h, infra: 13h, costs: 200h, dashboard: 25h, blog: 200h

## Proposal lifecycle

```
pending → approved (by Merox /approve) → applied (next orchestrator run)
pending → rejected (by Merox /reject) → archived in history
pending → expired (7 days, auto-cleaned)
```

## Dashboard integration

After each run, add `orchestrator` key to `agents.json`:
```json
{
  "orchestrator": {
    "lastRun": "2026-05-29T12:00:00Z",
    "status": "ok",
    "summary": "4/4 agenți OK, 0 probleme, 1 propunere pending"
  }
}
```
