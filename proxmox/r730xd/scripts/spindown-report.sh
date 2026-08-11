#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin, and smartctl/storcli/
# zpool live in /usr/sbin - without this they are silently not found and every
# check reports a false failure.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Passive sample - touches NO disk. idrac= the averaged "Pwr Consumption"
# sensor (what the BMC UI shows, lags minutes); inst= DCMI instantaneous
# (responds at once, reads a few W higher on its own scale).
LOG=/var/log/spindown-history.log
IDRAC=$(ipmitool sensor 2>/dev/null | grep -i "Pwr Consumption" | awk -F'|' '{print $2}' | xargs | cut -d. -f1)
INST=$(ipmitool dcmi power reading 2>/dev/null | awk '/Instantaneous/ {print $4}')
IO=$(/root/scripts/sas-disks.sh | awk '{print $1}' | while read -r d; do
       awk -v d="$d" '$3==d {print $4+$8}' /proc/diskstats; done | paste -sd+ | bc 2>/dev/null)
SLEPT=$(journalctl -t sas-spindown --since "-10min" 2>/dev/null | grep -c "standby issued" || true)
echo "$(date '+%F %H:%M') idrac=${IDRAC:-?}W inst=${INST:-?}W io=${IO:-?} standby_cmds=${SLEPT:-0}" >> "$LOG"
