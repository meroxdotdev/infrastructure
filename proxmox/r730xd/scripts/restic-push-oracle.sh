#!/bin/bash
set -euo pipefail
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
export RESTIC_PASSWORD_FILE="/root/.restic-oracle-password"

HC_URL="https://hc-ping.com/REPLACE-ME-SEE-PRIVATE-NOTES"
trap '[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL/fail" || true' ERR

restic backup /media/backups/oracle-vps /media/backups/immich-postgres \
  /media/backups/pfsense /media/backups/longhorn-garage \
  /media/backups/synology-home /media/backups/tools /media/photos /root --tag nightly
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
restic check

[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
