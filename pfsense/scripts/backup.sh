#!/bin/sh
# Nightly pfSense config backup, run from the Cron package at 03:00.
#
# The NAS keeps the latest copy only; history is the vault's job (daily ZFS
# snapshots) — see docs/architecture.md. The upload is atomic: a
# .part file renamed over the old one, so an interrupted run never leaves a
# truncated config.xml.gz where a good one was.
#
# The NAS user `pfsense` is SFTP-only and writes nowhere but backups/. Its key
# is /root/.ssh/pfsense-backup, accepted only from 10.57.57.1.
set -eu

KEY=/root/.ssh/pfsense-backup
TMP=$(mktemp /tmp/config.xml.gz.XXXXXX)
trap 'rm -f "$TMP"' EXIT
gzip -c /cf/conf/config.xml > "$TMP"

sftp -i "$KEY" -o BatchMode=yes -b - pfsense@10.57.57.201 <<SFTP
put $TMP /backups/pfsense/config.xml.gz.part
rename /backups/pfsense/config.xml.gz.part /backups/pfsense/config.xml.gz
SFTP
