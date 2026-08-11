#!/bin/bash
set -euo pipefail
DATASET="media/backups"
zfs snapshot -r "${DATASET}@daily-$(date +%F)"
CUTOFF=$(date -d "-14 days" +%s)
zfs list -H -o name -t snapshot -r "$DATASET" | grep "@daily-" | while read -r snap; do
  snap_date="${snap##*@daily-}"
  snap_epoch=$(date -d "$snap_date" +%s 2>/dev/null) || continue
  [ "$snap_epoch" -lt "$CUTOFF" ] && zfs destroy "$snap"
done
