#!/bin/bash
# The power-off gate. Called at the end of every vault-nightly.sh run, and by a
# cron job at W + 3 h as the backstop for a run that hung. See
# docs/plan-truenas-vault.md §6.
#
# It powers the vault off unless one of these holds:
#   - HOLD exists in vault/system. "Keep on" on Telegram writes it with
#     "until-next-run", and the next day's run removes it and asks again.
#     A HOLD made by hand (`touch`) stays until it is removed by hand.
#   - a resilver is running. A replaced disk resilvers to the end, however long.
# And it waits, up to W + 2 h, for a scrub or a SMART self-test; past that it
# pauses the scrub (it resumes on the next boot) and aborts the test.
#
# Every time, 5 minutes before powering off, Telegram asks with two buttons.
# Silence means off: a missed message never leaves the vault running.
set -uo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

POOL=/mnt/vault
SYS=$POOL/system
# shellcheck source=/dev/null
. "$SYS/secrets/vault.env"
mkdir -p "$SYS/logs" "$SYS/run"
exec >>"$SYS/logs/nightly-$(date +%F).log" 2>&1

exec 8>"$SYS/run/gate.lock"
flock -n 8 || exit 0
say() { echo "$(date -Is) gate: $*"; }

held() { [ -e "$SYS/HOLD" ]; }
if held; then say "HOLD present, staying on"; exit 0; fi

deadline=$(date -d "today $W + 2 hours" +%s)

while zpool status vault | grep -q "resilver in progress"; do
  say "resilver running, waiting"; sleep 300
done

while zpool status vault | grep -q "scrub in progress"; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    say "pausing scrub, it resumes at the next boot"; zpool scrub -p vault; break
  fi
  sleep 60
done

# The pool disks are the rotational ones; the boot SSDs are not.
sas_disks() { lsblk -dno NAME,ROTA | awk '$2 == 1 {print $1}'; }
testing() { smartctl -l selftest "/dev/$1" | grep -q "in progress"; }
for d in $(sas_disks); do
  while testing "$d"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "aborting SMART test on $d, next month retries"; smartctl -X "/dev/$d" >/dev/null; break
    fi
    sleep 60
  done
done

# --- Ask -----------------------------------------------------------------------
tg() { curl -fsS -m 70 "https://api.telegram.org/bot$TG_TOKEN/$1" "${@:2}"; }

ask() {
  local at offset msg reply
  at=$(date -d "+5 min" +%H:%M)
  # Start reading after the newest update, so an old button press cannot answer.
  offset=$(tg getUpdates -d offset=-1 | jq '(.result[-1].update_id // 0) + 1') || return 1
  msg=$(tg sendMessage -d chat_id="$TG_CHAT" \
    --data-urlencode text="🗄 Vault shuts down at $at" \
    --data-urlencode reply_markup='{"inline_keyboard":[[{"text":"Keep on","callback_data":"keep"},{"text":"Shut down now","callback_data":"off"}]]}' \
    | jq '.result.message_id') || return 1

  local until=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "$until" ]; do
    reply=$(tg getUpdates -d offset="$offset" -d timeout=50 -d allowed_updates='["callback_query"]') || { sleep 10; continue; }
    while read -r u; do
      offset=$(( $(jq '.update_id' <<<"$u") + 1 ))
      [ "$(jq '.callback_query.message.message_id' <<<"$u")" = "$msg" ] || continue
      [ "$(jq -r '.callback_query.message.chat.id' <<<"$u")" = "$TG_CHAT" ] || continue
      tg answerCallbackQuery -d callback_query_id="$(jq -r '.callback_query.id' <<<"$u")" >/dev/null || true
      case "$(jq -r '.callback_query.data' <<<"$u")" in
        keep)
          echo until-next-run > "$SYS/HOLD"
          tg editMessageText -d chat_id="$TG_CHAT" -d message_id="$msg" \
            --data-urlencode text="🗄 Vault stays on until tomorrow's run" >/dev/null || true
          return 0 ;;
        off)
          tg editMessageText -d chat_id="$TG_CHAT" -d message_id="$msg" \
            --data-urlencode text="🗄 Vault shutting down" >/dev/null || true
          return 1 ;;
      esac
    done < <(jq -c '.result[]' <<<"$reply")
  done
  tg editMessageText -d chat_id="$TG_CHAT" -d message_id="$msg" \
    --data-urlencode text="🗄 Vault shut down at $at, no answer" >/dev/null || true
  return 1
}

if ask; then say "kept on from Telegram"; exit 0; fi
held && { say "HOLD appeared while asking, staying on"; exit 0; }

say "powering off"
midclt call system.shutdown "vault-gate" >/dev/null || shutdown -h now
