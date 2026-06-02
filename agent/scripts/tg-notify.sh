#!/usr/bin/env bash
# Usage: tg-notify.sh "message text"
# Sends a Telegram message to Merox via the configured bot.
# Safe to call from any agent or cron script.

set -euo pipefail

BOT_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
CHAT_ID="YOUR_TELEGRAM_CHAT_ID"
MESSAGE="${1:-}"

if [[ -z "$MESSAGE" ]]; then
    echo "Usage: tg-notify.sh 'message'" >&2
    exit 1
fi

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d text="${MESSAGE}" \
    -d parse_mode="Markdown" \
    --max-time 10 \
    > /dev/null

echo "[tg-notify] sent: ${MESSAGE:0:60}..."
