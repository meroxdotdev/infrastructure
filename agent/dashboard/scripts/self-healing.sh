#!/bin/bash
# Self-healing: check agent staleness and restart if needed
# Called at end of infra agent runs or standalone

AGENTS_JSON="/srv/dashboard/data/agents.json"
LOG="/home/openclaw/.openclaw/logs/self-healing.log"
TG_SCRIPT="/srv/dashboard/tg-notify.sh"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

now_epoch=$(date -u +%s)

# Fix malformed timestamps in agents.json first
python3 - << 'EOF'
import json, sys
path = '/srv/dashboard/data/agents.json'
with open(path) as f:
    d = json.load(f)
changed = False
for key in d:
    lr = d[key].get('lastRun', '')
    if lr.endswith('+00:00Z'):
        d[key]['lastRun'] = lr.replace('+00:00Z', 'Z'); changed = True
    elif lr.endswith('+00:00'):
        d[key]['lastRun'] = lr[:-6] + 'Z'; changed = True
if changed:
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
    print("sanitized timestamps")
EOF

# Staleness thresholds (hours)
declare -A THRESHOLDS=(
    ["news"]=25
    ["infra"]=22
    ["dashboard"]=25
    ["orchestrator"]=25
    ["costs"]=170  # weekly
    ["blog"]=170   # weekly
)

declare -A AGENT_MSGS=(
    ["infra"]="HEARTBEAT"
    ["dashboard"]="HEARTBEAT"
    ["orchestrator"]="HEARTBEAT"
)

RESTARTED=()

for agent in news infra dashboard orchestrator; do
    threshold=${THRESHOLDS[$agent]}
    last_run=$(python3 -c "
import json
with open('$AGENTS_JSON') as f:
    d = json.load(f)
print(d.get('$agent', {}).get('lastRun', ''))
" 2>/dev/null)

    if [ -z "$last_run" ]; then
        log "WARN: $agent has no lastRun recorded"
        continue
    fi

    last_epoch=$(date -u -d "${last_run/Z/+00:00}" +%s 2>/dev/null || date -u -d "$last_run" +%s 2>/dev/null)
    if [ -z "$last_epoch" ]; then
        log "WARN: could not parse lastRun for $agent: $last_run"
        continue
    fi

    age_hours=$(( (now_epoch - last_epoch) / 3600 ))

    if [ "$age_hours" -gt "$threshold" ]; then
        log "STALE: $agent — last ran ${age_hours}h ago (threshold: ${threshold}h) — restarting"
        if [ "$agent" = "news" ]; then
            /srv/dashboard/news-morning-run.sh >> "/home/openclaw/.openclaw/logs/heartbeat-news.log" 2>&1 &
        else
            msg=${AGENT_MSGS[$agent]}
            /usr/bin/openclaw agent --agent "$agent" --message "$msg" >> "/home/openclaw/.openclaw/logs/heartbeat-${agent}.log" 2>&1 &
        fi
        RESTARTED+=("$agent (${age_hours}h stale)")
    else
        log "OK: $agent — last ran ${age_hours}h ago"
    fi
done

# Send Telegram alert if we restarted anything
if [ ${#RESTARTED[@]} -gt 0 ]; then
    msg="🔧 Self-healing: am repornit automat: ${RESTARTED[*]}"
    log "Sending Telegram alert: $msg"
    if [ -x "$TG_SCRIPT" ]; then
        "$TG_SCRIPT" "$msg"
    fi
fi

log "Self-healing check complete"

# Weekly self-improvement report (every Sunday)
DOW=$(date +%u)  # 7 = Sunday
if [ "$DOW" = "7" ]; then
    REPORT_FILE="/home/openclaw/.openclaw/workspace/memory/selfheal-$(date +%Y-%m-%d).md"
    if [ ! -f "$REPORT_FILE" ]; then
        python3 - << 'PYEOF'
import json
from datetime import datetime, timezone

path = '/srv/dashboard/data/agents.json'
with open(path) as f:
    d = json.load(f)

today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
lines = [f"# Self-Healing Report — {today}\n\n## Agent Status\n\n"]
for k, v in d.items():
    if k.startswith('_'):
        continue
    lines.append(f"- **{k}**: {v.get('status','?')} — last run {v.get('lastRun','?')[:19]} — {v.get('summary','')[:80]}\n")

report_path = f"/home/openclaw/.openclaw/workspace/memory/selfheal-{today}.md"
with open(report_path, 'w') as f:
    f.writelines(lines)
print(f"Written {report_path}")
PYEOF
        log "Weekly self-improvement report written"
    fi
fi
