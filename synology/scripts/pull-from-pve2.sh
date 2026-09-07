#!/bin/bash
# Weekly copy of pve-2's backup set onto this NAS.
#
# This used to be weekly-push-to-synology.sh running on pve-2, which held a key
# to this machine and ran rsync --delete against it. That made the NAS copy
# destroyable from pve-2 - the same host whose compromise is the reason the copy
# exists. Together with the off-site repository, which pve-2 could also prune,
# all three copies of everything were reachable from one machine. That is not
# 3-2-1; it is one copy in three places.
#
# Inverted, pve-2 holds no credential that reaches this NAS at all. It cannot
# write here and it cannot delete here, because nothing here trusts it. The
# trust runs the other way: this host holds two keys into pve-2, each pinned by
# authorized_keys to `rrsync -ro` over exactly one directory and to this IP, so
# neither can write to pve-2 either, nor reach /media/library or /media/isos.
# Verified 2026-09-07: writing back returns "sending to read-only server is not
# allowed", and any non-rsync command returns "SSH_ORIGINAL_COMMAND does not run
# rsync".
#
# Retention runs here too, for the same reason: the host that can delete these
# copies should not be the host being backed up.
#
# No `set -e`. The push version had it, and one missing source directory aborted
# the run so every category after it was skipped silently. Failures are counted
# and reported instead.
set -uo pipefail

HC_URL="https://hc-ping.com/REPLACE-ME-SEE-PRIVATE-NOTES"
SRC_HOST="root@10.57.57.250"
DEST_BASE="/volume1/NetBackup"
KEY_BACKUPS="/var/services/homes/admin/.ssh/nas-pull-backups"
KEY_PHOTOS="/var/services/homes/admin/.ssh/nas-pull-photos"
DATE=$(date +%Y-%m-%d)
RETENTION_DAYS=21
LOG="$DEST_BASE/.pull-from-pve2.log"
FAILED=0

exec 9>/tmp/pull-from-pve2.lock
flock -n 9 || { echo "another run is in progress"; exit 0; }

ssh_for() { echo "ssh -i $1 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"; }

pull_category() {
  local name="$1" key="$2" remote="$3"
  local dest_dir="$DEST_BASE/$name"
  local S; S=$(ssh_for "$key")

  mkdir -p "$dest_dir" || { echo "✗ $name: cannot create $dest_dir"; FAILED=$((FAILED+1)); return; }

  # Hardlink unchanged files against the most recent dated copy, so a weekly
  # snapshot costs only what changed.
  local latest link_dest=()
  latest=$(ls -1 "$dest_dir" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort | tail -1)
  if [ -n "$latest" ] && [ "$latest" != "$DATE" ]; then
    link_dest=(--link-dest="../$latest")
  fi

  echo "→ $name (dedup against: ${latest:-none, first run})"
  if ! rsync -avh --delete "${link_dest[@]}" -e "$S" "$SRC_HOST:$remote" "$dest_dir/$DATE/"; then
    echo "✗ $name: rsync failed"
    FAILED=$((FAILED+1))
    return
  fi

  # Prune by the date encoded in the directory name, never by filesystem mtime:
  # rsync -a stamps the source's mtime onto the destination, so an old snapshot
  # can look newer than it is.
  local cutoff; cutoff=$(date -d "-$RETENTION_DAYS days" +%Y-%m-%d)
  local d base
  for d in "$dest_dir"/*/; do
    base=$(basename "$d")
    case "$base" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if [[ "$base" < "$cutoff" ]]; then
      echo "  pruning $name/$base"
      rm -rf "$d"
    fi
  done
}

{
  echo "=== pull start $(date) ==="

  pull_category photos "$KEY_PHOTOS" "/"

  # Categories are read from pve-2 rather than listed here, so a new backup
  # category is copied automatically instead of being forgotten. The hardcoded
  # list this replaces had never included etcd/ and still named a directory that
  # had been removed.
  S=$(ssh_for "$KEY_BACKUPS")
  cats=$(rsync -e "$S" --list-only "$SRC_HOST:/" 2>/dev/null \
         | awk '$1 ~ /^d/ && $NF != "." {print $NF}')
  if [ -z "$cats" ]; then
    echo "✗ could not list categories on pve-2"
    FAILED=$((FAILED+1))
  else
    for c in $cats; do
      pull_category "$c" "$KEY_BACKUPS" "/$c/"
    done
  fi

  echo "=== pull done $(date), failures: $FAILED ==="
} >> "$LOG" 2>&1

if [ "$FAILED" -gt 0 ]; then
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "failed:$FAILED" "$HC_URL/fail" || true
  exit 1
fi
curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
