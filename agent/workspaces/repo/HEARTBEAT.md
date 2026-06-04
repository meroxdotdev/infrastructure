# HEARTBEAT.md — Repo Agent

Runs once per week: **Monday 07:00 UTC** (10:00 EEST).

Also runs on-demand when Merox asks: "repo audit", "check repos", "sync workspaces".

## Checklist

```
[ ] docker ps vs README services
[ ] paths in README/DEPLOY.md exist on disk
[ ] workspace templates vs live workspaces (diff)
[ ] orphaned .bak/.old files in /srv/
[ ] uncommitted changes in git repos
[ ] compose files: no hardcoded secrets (grep PASSWORD/TOKEN/SECRET)
[ ] Tailscale key — ask Merox if >60 days since last rotation
```

## Run each check

```bash
# 1. Running containers
docker ps --format "{{.Names}}" | sort

# 2. Workspace drift — diff each template vs live
for ws in news blog design infra costs dashboard orchestrator renovate repo; do
  live="/home/openclaw/.openclaw/workspace-${ws}"
  template="/srv/kubernetes/infrastructure/agent/workspaces/${ws}"
  [ "$ws" = "news" ] && live="/home/openclaw/.openclaw/workspace"
  [ -d "$live" ] && [ -d "$template" ] && \
    diff -rq --exclude="memory" --exclude="*.log" "$template" "$live" && \
    echo "$ws: in sync" || echo "$ws: DRIFT DETECTED"
done

# 3. Orphaned files
find /srv -name "*.bak" -o -name "*.old" -o -name "*.tmp" 2>/dev/null | \
  grep -v ".git" | grep -v "node_modules"

# 4. Git status
git -C /srv/kubernetes/infrastructure status --short | grep "^[^?]"
git -C /srv/docker/oracle-cloud status --short | grep "^[^?]"

# 5. Hardcoded secrets check
grep -rE "(PASSWORD|TOKEN|SECRET)\s*[:=]\s*['\"][^$'\"{]" \
  /srv/docker/oracle-cloud/ --include="*.yml" --include="*.yaml" \
  --exclude-dir=".git" 2>/dev/null | grep -v "change_me\|example\|your_"
```

## Telegram — when to send

**Send always** (even if clean):
```
✅ Repo audit — tutto OK
Ultima verificare: <data>
```

**Send with commands** if drift found:
```
🔧 Repo audit — <N> lucruri de actualizat

1. workspace-infra: AGENTS.md s-a schimbat live
\`\`\`
cp /home/openclaw/.openclaw/workspace-infra/AGENTS.md \
   /srv/kubernetes/infrastructure/agent/workspaces/infra/AGENTS.md
cd /srv/kubernetes/infrastructure && git add agent/workspaces/infra/AGENTS.md
git commit -m "sync: update infra workspace template" && git push
\`\`\`

2. ...
```

## Telegram send

```python
import json, urllib.request, urllib.parse

config  = json.load(open('/home/openclaw/.openclaw/openclaw.json'))
TOKEN   = config['channels']['telegram']['botToken']
CHAT_ID = config['channels']['telegram']['allowFrom'][0]

msg = "✅ Repo audit — tutto OK\nUltima verificare: " + datetime.now().strftime('%d %b %Y %H:%M')

data = urllib.parse.urlencode({
    "chat_id": CHAT_ID, "text": msg, "parse_mode": "Markdown"
}).encode()
urllib.request.urlopen(
    urllib.request.Request(
        f"https://api.telegram.org/bot{TOKEN}/sendMessage",
        data=data, method="POST"
    ), timeout=10
)
```
