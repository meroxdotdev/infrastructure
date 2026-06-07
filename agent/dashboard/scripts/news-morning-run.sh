#!/bin/bash
# Wrapper for news agent morning cron — fresh session per day, explicit task trigger
SESSION_KEY="morning-$(date -u +%Y-%m-%d)"
exec /usr/bin/openclaw agent --agent news --session-key "$SESSION_KEY" --message "MORNING_RUN"
