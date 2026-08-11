#!/bin/bash
set -e
rsync -avh --delete -e "ssh -i /root/.ssh/pve-to-synology -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" admin@10.57.57.201:/volume1/homes/merox/ /media/backups/synology-home/ >> /var/log/synology-home-backup.log 2>&1
zfs snapshot media/backups/synology-home@$(date +%Y-%m-%d)
zfs list -t snapshot -o name -H media/backups/synology-home | while read snap; do
  snap_date=$(echo "$snap" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  if [ -n "$snap_date" ]; then
    snap_epoch=$(date -d "$snap_date" +%s)
    cutoff_epoch=$(date -d "30 days ago" +%s)
    if [ "$snap_epoch" -lt "$cutoff_epoch" ]; then
      zfs destroy "$snap"
    fi
  fi
done
