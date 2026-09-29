#!/bin/sh
# Nightly pfSense config backup, run from the Cron package at 03:00.
#
# The NAS keeps the latest copy only; history is the vault's job (daily ZFS
# snapshots) — see docs/plan-nas-hot-r730-cold.md. The upload is atomic: a
# .part file renamed over the old one, so an interrupted run never leaves a
# truncated config.xml.gz where a good one was.
#
# The NAS user `pfsense` is SFTP-only and writes nowhere but backups/. Its key
# is /root/.ssh/pfsense-backup, accepted only from 10.57.57.1.
set -eu

KEY=/root/.ssh/pfsense-backup
# The dated name matters for pve-2 only: its receiver keeps the source file
# name and prunes `config-*.xml.gz` after 30 days.
TMP=/tmp/config-$(date +%Y-%m-%d_%H%M%S).xml.gz
trap 'rm -f "$TMP"' EXIT
gzip -c /cf/conf/config.xml > "$TMP"

sftp -i "$KEY" -o BatchMode=yes -b - pfsense@10.57.57.201 <<SFTP
put $TMP /backups/pfsense/config.xml.gz.part
rename /backups/pfsense/config.xml.gz.part /backups/pfsense/config.xml.gz
SFTP

# TEMPORARY, remove in phase 7: pve-2's restic push is still the off-site path
# until the vault takes over. Its receiver keeps 30 days of dated copies.
scp -O -i "$KEY" -o BatchMode=yes "$TMP" root@10.57.57.250:
