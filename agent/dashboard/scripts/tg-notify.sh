#!/usr/bin/env bash
# Usage: tg-notify.sh "message text"
# Reads credentials from /srv/dashboard/.env

set -euo pipefail

ENV_FILE="/srv/dashboard/.env"
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
MESSAGE="${1:-}"

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set in $ENV_FILE" >&2
    exit 1
fi

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
