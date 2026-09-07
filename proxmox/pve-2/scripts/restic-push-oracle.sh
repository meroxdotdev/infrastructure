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
# --group-by host, not the default host+paths. Retention is per group, so
# changing the backup path set would otherwise strand every older snapshot in
# a group nothing new ever enters — pinned forever, never pruned. Grouping by
# host alone lets the policy span a path change.
restic forget --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
# `restic check` on its own reads metadata: the index, the tree structure, that
# every referenced pack file is present. It never opens those packs, so it
# passes over a repository whose data has rotted. --read-data-subset opens them,
# and it is the only check in this estate that can fail on bit rot.
#
# 5% weekly rather than a fraction nightly. The repository is 64 GiB and lives
# on a borrowed Oracle tenancy reached over the tailnet, so reading it is egress
# on someone else's account: 5% is ~3.2 GiB a week, while rotating a seventh
# each night - the obvious way to cover the whole repo faster - would be ~276
# GiB a month. Complete coverage is not worth that on hardware that is not ours.
#
# Sunday, after the weekly Synology push at 03:15 has had its turn on Sundays
# too; both are read-heavy but neither is time-critical.
if [ "$(date +%u)" = "7" ]; then
  restic check --read-data-subset=5%
else
  restic check
fi

[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
