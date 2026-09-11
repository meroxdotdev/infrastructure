#!/bin/bash
set -euo pipefail
# rest-server on vps01 in --append-only mode, not the old SFTP chroot. Same
# repository on the same disk - nothing was copied - reached a different way.
# Over SFTP this host could delete the off-site copy; over this endpoint it
# cannot. Proven by curl on 2026-09-07: DELETE on a data pack returns 403,
# DELETE on a lock returns 200 (restic needs that to run at all), a wrong
# password returns 401.
#
# Credentials live in the URL because restic's rest backend accepts them
# nowhere else. Built here rather than written inline so the password stays in a
# 0600 file instead of this repository.
export RESTIC_PASSWORD_FILE="/root/.restic-oracle-password"
export RESTIC_REPOSITORY="rest:http://pve-2:$(cat /root/.restic-rest-password)@100.72.22.38:8000/"

HC_URL="https://hc-ping.com/REPLACE-ME-SEE-PRIVATE-NOTES"
trap '[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL/fail" || true' ERR

# One path, not an enumerated list. The old version named each subdirectory of
# /media/backups individually, so a new backup category was silently left out
# until someone noticed — the same drift that kept the Immich library out of
# the DR restore for months. Whatever lands under /media/backups is covered.
# /media/backups/dump is excluded, and it is the one exclusion here with a
# reason rather than an oversight. It holds weekly vzdump images of VM 1000,
# the only guest in the estate not rebuilt from git. Each is ~8-10 GiB
# compressed, and the Oracle repository sits at 67 GiB on a disk with 77 GiB
# free, so a few of them would fill it. They still get two copies off this
# machine - the local array and the Synology pull, which has 1.5 TB free - and
# a machine image is worth restoring over the LAN, not over the tailnet from
# Frankfurt. The data inside Nextcloud is backed up separately under
# /media/backups/nextcloud and does go off-site.
restic backup /media/backups /media/photos /root --tag nightly \
  --exclude /media/backups/dump
# No forget, no prune. Both are refused by the append-only endpoint, and that is
# the entire point of moving to it: this host can add backups and can no longer
# remove one. Retention runs on vps01 instead, as restic-retention.timer, which
# reaches the repository through the filesystem rather than through the port.
#
# It also uses --keep-within-* rather than --keep-daily N. A counted policy can
# be turned against itself: append-only stops deletion but not insertion, so a
# compromised client that writes a batch of cheap snapshots pushes the real ones
# out of the retention window and the trusted host deletes them on its behalf.
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

# Reaching this line means backup and check both succeeded (set -e), so this
# is the moment worth recording. Written for Grafana through node_exporter's
# textfile collector: the Homelab Overview shows how long ago the off-site copy
# last completed. Healthchecks.io still does the alerting; this is visibility.
#
# `|| true` is load-bearing. A metric that cannot be written must never reach
# the ERR trap above and report a successful backup as failed. The .tmp name
# is invisible to the collector, which only reads *.prom, and mv is atomic.
PROM=/var/lib/prometheus/node-exporter/backup-offsite.prom
{ printf '# HELP backup_last_success_timestamp_seconds Unix time a backup leg last completed.\n# TYPE backup_last_success_timestamp_seconds gauge\nbackup_last_success_timestamp_seconds{leg="offsite"} %s\n' "$(date +%s)" > "$PROM.tmp" && mv "$PROM.tmp" "$PROM"; } 2>/dev/null || true

[ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
