#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Outcome-based: rather than checking that each known waker is still silenced,
# ask whether the disks actually slept. That catches wakers nobody has thought
# of, and cannot rot the way a checklist does.
set -uo pipefail
LOG=/var/log/spindown-history.log
ALERT=""
ratio() {   # $1 = from, $2 = until. Prints "pct samples"; pct=-1 if too few.
  awk -v cut="$1" -v until="${2:-9999}" '
    { ts=substr($0,1,16)
      # Only lines carrying the marker are evidence either way - a line in an
      # older format must not count as "not parked".
      if (ts>=cut && ts<until && match($0,/asleep=[0-9]+\/[0-9]+/)) { n++
          split(substr($0,RSTART+7,RLENGTH-7), a, "/")
          if (a[1]+0 == a[2]+0 && a[2]+0 > 0) c++ } }
    END { if (n>=6) printf "%d %d", (c+0)*100/n, n; else printf "-1 %d", n+0 }' "$LOG" 2>/dev/null
}
read -r pct n <<< "$(ratio "$(date -d '-24 hours' '+%F %H:%M')")"
read -r base bn <<< "$(ratio "$(date -d '-8 days' '+%F %H:%M')" "$(date -d '-24 hours' '+%F %H:%M')")"
# Absolute floor: something is plainly keeping the disks awake.
if [ "$pct" -ge 0 ] && [ "$pct" -lt 30 ]; then
  ALERT="$ALERT\nDisks fully parked in only ${pct}% of the last 24h (${n} samples)."
# Relative drop: still above the floor, but well below this host's own norm -
# catches gradual decay that a fixed threshold would never trip.
elif [ "$pct" -ge 0 ] && [ "$base" -ge 50 ] && [ "$pct" -lt $(( base * 6 / 10 )) ]; then
  ALERT="$ALERT\nDisks parked ${pct}% of the last 24h, against a ${base}% baseline\nover the previous 7 days. Something new is waking them."
fi
if command -v storcli >/dev/null 2>&1; then
  pr=$(storcli /c0 show patrolread 2>/dev/null | grep -c "PR Mode.*Disable" || true)
  [ "${pr:-0}" -eq 0 ] && ALERT="$ALERT\nController patrol read is no longer disabled."
fi
# grep -c, not grep -q: -q exits on the first match, journalctl takes SIGPIPE
# and returns 141, which under pipefail reads as a failed check.
sd=$(journalctl -u smartmontools -b --no-pager 2>/dev/null | grep -c "0 SCSI/SAS" || true)
[ "${sd:-0}" -eq 0 ] && ALERT="$ALERT\nsmartd is watching the spinning disks again - it will keep waking them."
systemctl is-active --quiet sas-spindown.timer || ALERT="$ALERT\nsas-spindown.timer is not active."
if [ -n "$ALERT" ]; then
  echo -e "$(date '+%F %T') DRIFT:$ALERT"
  exit 1
else
  if [ "$pct" -lt 0 ]; then
    echo "$(date '+%F %T') ok (only ${n} samples in 24h - too few to judge yet)"
  else
    echo "$(date '+%F %T') ok (24h parked: ${pct}% of ${n} samples, baseline: $([ "$base" -ge 0 ] && echo "${base}%" || echo "building"))"
  fi
fi
