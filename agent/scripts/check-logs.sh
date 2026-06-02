#!/bin/bash
TG_SCRIPT="/srv/dashboard/tg-notify.sh"
LOGS_DIR="/home/openclaw/.openclaw/logs"
AGENTS=(news infra dashboard orchestrator costs blog)
ERRORS=()
NOW=$(date +%s)
TWO_HOURS=7200

for agent in "${AGENTS[@]}"; do
    log="$LOGS_DIR/heartbeat-${agent}.log"
    [ -f "$log" ] || continue

    file_mtime=$(stat -c %Y "$log" 2>/dev/null || echo 0)
    age=$(( NOW - file_mtime ))

    if [ "$age" -lt "$TWO_HOURS" ]; then
        if tail -100 "$log" | grep -qi "traceback\|exception\|rate.limit\|quota"; then
            last_err=$(tail -100 "$log" | grep -i "traceback\|exception\|rate.limit\|quota" | tail -1 | cut -c1-120)
            ERRORS+=("🔴 $agent: $last_err")
        fi
    fi
done

if [ ${#ERRORS[@]} -gt 0 ]; then
    msg="⚠️ Erori detectate în agenți:"$'\n'
    for e in "${ERRORS[@]}"; do msg+="$e"$'\n'; done
    [ -x "$TG_SCRIPT" ] && "$TG_SCRIPT" "$msg"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sent alert: ${ERRORS[*]}"
else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] No errors found"
fi
