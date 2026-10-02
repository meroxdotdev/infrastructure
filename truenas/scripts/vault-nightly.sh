#!/bin/bash
# The vault's daily run: pull from the NAS, snapshot, push to Oracle, verify,
# then hand over to the power-off gate. See truenas/RUNBOOK.md.
#
# Two triggers, one run per day. vault-init.sh starts it at boot (the normal
# case: pve-3 woke the vault at W). A cron job at W + 10 min starts it too, for
# the days the vault was kept on and never booted. A lock and a date stamp make
# the second trigger a no-op once the first has run.
#
# This script orders standard tools and stops at the first failure. Whatever
# happens, the gate runs at the end: a failed run still asks before powering
# off, so a broken night never leaves the vault on, and never takes it down
# under someone who is debugging it.
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

POOL=/mnt/vault
SYS=$POOL/system
# W, the healthchecks URL, the Telegram bot, the restic credentials. Kept out of
# this public repository; the template is truenas/vault.env.example.
# shellcheck source=/dev/null
. "$SYS/secrets/vault.env"

mkdir -p "$SYS/logs" "$SYS/run" "$SYS/config"
exec >>"$SYS/logs/nightly-$(date +%F).log" 2>&1

exec 9>"$SYS/run/nightly.lock"
flock -n 9 || { echo "$(date -Is) another run holds the lock, exiting"; exit 0; }
if [ "$(cat "$SYS/run/last-run" 2>/dev/null)" = "$(date +%F)" ]; then
  echo "$(date -Is) already ran today, exiting"
  exit 0
fi

STEP=start
step() { STEP=$1; echo "$(date -Is) == $1"; }
hc()   { curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "${2:-}" "$HC_URL$1" || true; }

# Success is reaching the last line, not a zero exit status: a run killed by a
# signal (a power cut, a reboot, a kill) runs this trap with a status that
# can read as 0, and would otherwise be stamped and reported as done.
COMPLETED=0
finish() {
  local rc=$?
  if [ "$COMPLETED" = 1 ]; then
    date +%F > "$SYS/run/last-run"
    hc "" "ok"
  else
    hc "/fail" "failed at: $STEP (exit $rc)"
  fi
  # A held vault from yesterday is asked again today: the hold lasts one run.
  "$SYS/scripts/vault-gate.sh" || true
}
trap finish EXIT
trap 'exit 143' TERM INT HUP

# A "Keep on" from yesterday's question expires now; the gate below asks
# afresh. A HOLD made by hand (empty file) stays until it is removed by hand.
[ "$(cat "$SYS/HOLD" 2>/dev/null)" = until-next-run ] && rm -f "$SYS/HOLD"
hc "/start"

# --- 1. Pull from the NAS, read-only ------------------------------------------
# DSM's rsync daemon as an ordinary user with read-only share permissions: the
# vault can read the NAS, the NAS holds nothing that reaches the vault. DSM
# needs an "rsync account" for daemon mode (File Services → rsync); it uses the
# same password as the DSM user, so there is one secret, not two.
#
# Excluded: DSM's own indexes and recycle bins, and what vault-pull rightly
# cannot read — every user's .ssh/ and the admin home. Unreadable files make
# rsync exit 23, which would fail the run every night.
#
# --max-delete=500: a source wiped or encrypted under a new name would delete
# everything here. Past 500 deletions rsync stops deleting and exits 25, set -e
# ends the run before any snapshot, and the last good one stays the newest.
step "pull from NAS"
for share in backups homes; do
  rsync -aH --delete --max-delete=500 --numeric-ids \
    --exclude '@eaDir/' --exclude '#recycle/' --exclude '.SynologyWorkingDirectory/' \
    --exclude '.ssh/' --exclude '/admin/' \
    --password-file="$SYS/secrets/rsync-password" \
    "rsync://vault-pull@$NAS_HOST/$share/" "$POOL/backup/nas/$share/"
done

# --- 2. Git mirrors --------------------------------------------------------------
# One URL per line in config/github-repos. A mirror is a full copy of every ref,
# so a deleted branch or a force-push upstream is still here in yesterday's
# snapshot.
step "git mirrors"
while read -r url; do
  [ -z "$url" ] || [ "${url#\#}" != "$url" ] && continue
  dir="$POOL/backup/github/$(basename "$url")"
  [ -d "$dir" ] || git clone --quiet --mirror "$url" "$dir"
  git -C "$dir" remote update --prune >/dev/null
done < "$SYS/config/github-repos"

# --- 3. TrueNAS configuration ----------------------------------------------------
# The database is all of TrueNAS's state. Its encrypted fields need pwenc_secret,
# which stays in secrets/ and so never leaves the vault; it is in the password
# manager for a rebuild from Oracle.
step "config export"
sqlite3 /data/freenas-v1.db ".backup '$SYS/config/truenas-config.db'"
install -m 600 /data/pwenc_secret "$SYS/secrets/pwenc_secret"

# --- 4. Snapshots ----------------------------------------------------------------
# TrueNAS owns naming and retention (a periodic task per dataset, plus a
# monthly one on backup); this only says "now". Only the tasks due today: the
# monthly task runs on its day of the month, not every night with a 12-month
# lifetime. run starts the snapshot and returns at once; it is not a job, and
# `midclt call -j` would wait forever for one. Nothing below reads from the
# snapshots — restic backs up the live datasets — so there is nothing to wait for.
step "snapshots"
for id in $(midclt call pool.snapshottask.query '[["enabled","=",true]]' |
            jq --arg d "$(date +%-d)" '.[] | select(.schedule.dom == "*" or
              (.schedule.dom | split(",") | index($d))) | .id'); do
  midclt call pool.snapshottask.run "$id" >/dev/null
done

# --- 5. Off-site -------------------------------------------------------------------
# Same repository the R730xd pushed to, through rest-server --append-only: this
# host can add snapshots and cannot remove one. Retention runs on the VPS.
# Content-defined chunking means the move to new paths uploads almost nothing.
step "restic backup"
export RESTIC_PASSWORD_FILE="$SYS/secrets/restic-password"
# On the pool, not in root's home on the boot pool: the cache is rebuilt from
# the repository if lost, but it should not fill the boot mirror.
export RESTIC_CACHE_DIR="$SYS/run/restic-cache"
RESTIC_REPOSITORY="rest:http://vault:$(cat "$SYS/secrets/rest-password")@$ORACLE_HOST:8000/"
export RESTIC_REPOSITORY
RESTIC=$SYS/bin/restic
"$RESTIC" backup --host vault --tag nightly \
  --exclude-file "$SYS/config/restic-excludes" \
  "$POOL/backup" "$POOL/files" "$POOL/system"

# Metadata every day; 5 % of the data itself on Sundays, the only check that
# can fail on bit rot, at ~3 GiB of egress a week on a borrowed tenancy.
step "restic check"
if [ "$(date +%u)" = 7 ]; then
  "$RESTIC" check --read-data-subset=5%
else
  "$RESTIC" check
fi

# --- 6. Restore drill, first day of the month ---------------------------------------
# Proves data comes back out, not only that the repository is consistent:
# restore two real paths and compare them byte for byte with what is live.
if [ "$(date +%d)" = 01 ]; then
  step "restore drill"
  drill=$(mktemp -d "$SYS/run/drill.XXXXXX")
  for path in "$POOL/backup/nas/backups/pfsense" "$POOL/backup/nas/backups/oracle-vps"; do
    "$RESTIC" restore latest --host vault --include "$path" --target "$drill" >/dev/null
    live=$(cd "$path" && find . -type f -exec sha256sum {} + | sort | sha256sum)
    back=$(cd "$drill$path" && find . -type f -exec sha256sum {} + | sort | sha256sum)
    [ "$live" = "$back" ] || { echo "drill: $path differs"; rm -rf "$drill"; exit 1; }
    echo "drill: $path ok"
  done
  rm -rf "$drill"
fi

# --- 7. Monthly maintenance --------------------------------------------------------
# Started here, by the run, not by the clock: a cron job at a fixed minute
# raced the gate, which could power off a test that had just begun. Started
# from the run, they are always running when the gate looks, and it waits for
# them (scrub paused, SMART aborted at W + 2 h).
#   Sundays: scrub, if the last one is older than 28 days — once a month.
#   First Sunday: SMART long test on every pool disk, ~70 min on these drives.
if [ "$(date +%u)" = 7 ]; then
  step "maintenance"
  midclt call pool.scrub.run vault 28 >/dev/null
  if [ "$(date +%-d)" -le 7 ]; then
    # smartctl, not midclt disk.smart_test: that call is unsupported in 25.10
    # and was seen to return without starting anything. Rotational disks are
    # the pool; the boot SSDs are not (ROTA=0).
    for d in $(lsblk -dno NAME,ROTA | awk '$2 == 1 {print $1}'); do
      smartctl -t long "/dev/$d" >/dev/null
    done
  fi
fi

step "done"
COMPLETED=1
