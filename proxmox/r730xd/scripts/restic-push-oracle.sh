#!/bin/bash
set -euo pipefail
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
export RESTIC_PASSWORD_FILE="/root/.restic-oracle-password"

HC_URL="https://hc-ping.com/REPLACE-ME-SEE-PRIVATE-NOTES"
trap '[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL/fail" || true' ERR

# One path, not an enumerated list. The old version named each subdirectory of
# /media/backups individually, so a new backup category was silently left out
# until someone noticed — the same drift that kept the Immich library out of
# the DR restore for months. Whatever lands under /media/backups is covered.
restic backup /media/backups /media/photos /root --tag nightly
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
restic check

[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
