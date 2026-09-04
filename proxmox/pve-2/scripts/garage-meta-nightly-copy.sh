#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin, and smartctl/storcli/
# zpool live in /usr/sbin - without this they are silently not found and every
# check reports a false failure.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Nightly copy of Garage's live meta (rpool/SSD - moved there 2026-08-07 so its
# constant LMDB/heartbeat writes stop waking the spun-down SAS pool) back into
# the old location on media/backups. Runs inside the nightly backup window when
# the disks are awake anyway, so every existing downstream leg (ZFS snapshots,
# restic->Oracle, weekly Synology push) keeps covering meta with zero scope changes.
set -euo pipefail
rsync -a --delete /rpool/garage-meta/ /media/backups/longhorn-garage/meta/
