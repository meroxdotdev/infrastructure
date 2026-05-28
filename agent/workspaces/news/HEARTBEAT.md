# HEARTBEAT.md — News Agent

Runs once daily at 07:00 Romanian time. Execute the morning briefing.

## Task

1. Check `memory/` for the last 3 days (do not repeat items already sent)
2. Search for relevant news for the stack in USER.md (GitHub releases, CVEs, community)
3. Write `/srv/dashboard/news.html` with a clean HTML dashboard
4. Send on Telegram: link `https://news.cloud.merox.dev` + 3-5 bullet points in Romanian
5. Update `/srv/dashboard/data/news.json` and `/srv/dashboard/data/agents.json`
6. Save to `memory/YYYY-MM-DD.md` what was sent

If nothing relevant: "📰 Stack liniștit azi — nimic critic de raportat."

Do not run if it's past 09:00 or before 06:30.
