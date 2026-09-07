#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# SMART health for disks smartd no longer watches. Sleeping disks are skipped
# rather than woken - they get checked on a night they happen to be awake - and
# "no data returned" is not treated as a fault.
set -uo pipefail
ALERT=""; skipped=0; total=0
while read -r d sg; do
  total=$((total+1))
  out=$(smartctl -n standby -H -l error "/dev/$sg" 2>&1)
  case "$out" in *STANDBY*) skipped=$((skipped+1)); continue ;; esac
  health=$(echo "$out" | grep -i "SMART Health Status" | awk -F: '{print $2}' | xargs)
  defects=$(smartctl -n standby -a "/dev/$sg" 2>/dev/null | grep -i "grown defect" | grep -oE '[0-9]+$')
  uncorr=$(echo "$out" | awk '/^read:|^write:|^verify:/ {print $NF}' | awk '{s+=$1} END {print s}')
  [ -n "$health" ] && [ "$health" != "OK" ] && ALERT="$ALERT\n$d: health=$health"
  [ "${defects:-0}" -gt 0 ] && ALERT="$ALERT\n$d: grown defects=$defects"
  [ "${uncorr:-0}" -gt 0 ] && ALERT="$ALERT\n$d: uncorrected errors=$uncorr"
done < <(/root/scripts/sas-disks.sh)
echo "$(date '+%F %T') checked $((total-skipped))/$total (${skipped} asleep), alert='${ALERT:-none}'"
# Reporting belongs to nightly-checks.sh, which runs this and the other two
# host checks and pings once. Exit code is the whole interface.
[ -n "$ALERT" ] && exit 1
exit 0
