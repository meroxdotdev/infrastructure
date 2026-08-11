#!/bin/bash
set -e
SSH_OPTS="ssh -i /root/.ssh/pve-to-synology -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
DEST_HOST="admin@10.57.57.201"
DEST_BASE="/volume1/NetBackup"
DATE=$(date +%Y-%m-%d)
LOG=/var/log/weekly-push-to-synology.log
RETENTION_DAYS=21

sync_category() {
  local name="$1" src="$2"
  local remote_dir="$DEST_BASE/$name"

  # Ensure the category top-level dir exists - matters on a brand-new
  # categorys first-ever run, since rsync wont create multiple missing
  # destination path levels on its own.
  $SSH_OPTS "$DEST_HOST" "mkdir -p '$remote_dir'"

  # Find the most recent existing dated snapshot to hardlink unchanged files from
  local latest
  latest=$($SSH_OPTS "$DEST_HOST" "ls -1 '$remote_dir' 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort | tail -1" || true)

  local link_dest_arg=()
  if [ -n "$latest" ] && [ "$latest" != "$DATE" ]; then
    link_dest_arg=(--link-dest="../$latest")
  fi

  echo "→ Syncing $name (dedup against: ${latest:-none, first run})"
  rsync -avh --delete "${link_dest_arg[@]}" -e "$SSH_OPTS" "$src" "$DEST_HOST:$remote_dir/$DATE/"

  # Prune by DATE ENCODED IN THE FOLDER NAME, not filesystem mtime — rsync -a
  # preserves the *source* directory own mtime onto the destination, which
  # has nothing to do with snapshot age (learned this the hard way: it wiped
  # a same-day snapshot immediately because the source dir mtime happened
  # to be old).
  echo "→ Pruning $name snapshots older than $RETENTION_DAYS days"
  $SSH_OPTS "$DEST_HOST" bash -s -- "$remote_dir" "$RETENTION_DAYS" << 'REMOTE_EOF'
    remote_dir="$1"
    retention_days="$2"
    cutoff=$(date -d "-${retention_days} days" +%Y-%m-%d)
    for snap in $(ls -1 "$remote_dir" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'); do
      if [[ "$snap" < "$cutoff" ]]; then
        echo "   removing old snapshot: $snap"
        rm -rf "${remote_dir:?}/${snap}"
      fi
    done
REMOTE_EOF
}

{
  echo "=== weekly push start $(date) ==="
  sync_category photos /media/photos/
  sync_category documents /media/backups/synology-home/
  sync_category vm-backups /media/backups/dump/
  sync_category pfsense /media/backups/pfsense/
  sync_category longhorn-garage /media/backups/longhorn-garage/
  sync_category immich-postgres /media/backups/immich-postgres/
  sync_category oracle-vps /media/backups/oracle-vps/
  sync_category tools /media/backups/tools/
  echo "=== weekly push done $(date) ==="
} >> "$LOG" 2>&1
