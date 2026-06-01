#!/usr/bin/env bash
# Usage: tg-notify.sh "message text"
# Sends a Telegram message to Merox via the configured bot.
# Safe to call from any agent or cron script.
#
# Required env vars (set in ~/.openclaw/.env):
#   TELEGRAM_BOT_TOKEN — from @BotFather
#   TELEGRAM_CHAT_ID   — your numeric user ID

set -euo pipefail

# Load env file if present
[ -f "${HOME}/.openclaw/.env" ] && source "${HOME}/.openclaw/.env"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set — add to ~/.openclaw/.env}"
CHAT_ID="${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID not set — add to ~/.openclaw/.env}"
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
