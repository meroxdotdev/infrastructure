#!/bin/bash
# Spin down idle SAS disks - idempotent installer.
#
# Parks rotating disks that sit unused, and keeps them parked. Written for SAS
# drives, where the usual tools quietly fail: they ignore ATA standby, and a
# SCSI standby sent to the block device is undone by the kernel a second later.
#
#   ./install-spindown.sh --check         # report state, change nothing
#   ./install-spindown.sh                 # install or repair
#   SAS_DISKS="sdb sdc sdd" ./install-spindown.sh
#   SAS_POOL=tank ./install-spindown.sh
#
# TESTED ON: Dell R730xd, PERC H730P in HBA mode (megaraid_sas), Debian 13 /
# Proxmox 9, ZFS pool of 12 SAS drives, iDRAC present. That is the only
# configuration this has actually run on.
#
# Everything else is written to degrade gracefully but is UNVERIFIED: other
# controllers (LSI IT-mode/mpt3sas), non-ZFS layouts, hosts without a BMC,
# other distributions. The mechanism is standard SCSI and should carry over -
# but run --check first, and confirm with the two-minute test in the README
# before trusting it with anything.
#
# Disks are found in this order: $SAS_DISKS, then a ZFS pool's members, then
# every rotational disk not backing /. Only rotational devices are ever
# touched, so an SSD cannot be parked by accident.
#
# Requires sg3-utils and smartmontools. Uses storcli and ipmitool when present.
#
# NOT handled: applications that keep writing to your disks. No installer can
# guess those. It sets up detection and alerting; see FINDING WRITERS at the end.
set -euo pipefail

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

say()  { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }

detect_pool() {
  local p id d
  command -v zpool >/dev/null 2>&1 || return 1
  for p in $(zpool list -H -o name 2>/dev/null); do
    for id in $(zpool status "$p" 2>/dev/null | grep -oE "wwn-0x[0-9a-f]+" | sort -u); do
      d=$(basename "$(readlink -f "/dev/disk/by-id/$id" 2>/dev/null)" 2>/dev/null)
      if [ -n "$d" ] && [ "$(cat "/sys/block/$d/queue/rotational" 2>/dev/null)" = "1" ]; then
        echo "$p"; return 0
      fi
    done
  done
  return 1
}

POOL="${SAS_POOL:-$(detect_pool || true)}"
DISKS_ARG="${SAS_DISKS:-}"

if   [ -n "$DISKS_ARG" ]; then MODE="explicit list ($DISKS_ARG)"
elif [ -n "$POOL" ];      then MODE="members of ZFS pool '$POOL'"
else                           MODE="all rotational disks not backing /"
fi

write_disk_list() {
  mkdir -p /root/scripts
  cat > /root/scripts/sas-disks.sh <<SH
#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin, while smartctl, storcli
# and zpool live in /usr/sbin. Without this they are silently not found and
# every check reports a false failure.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Prints "sdX sgN" per line for the disks to manage. Re-derived on every run,
# so replacing a disk or moving a slot needs no edits. Non-rotational devices
# are filtered out last, whichever source was used - an SSD can never appear.
set -uo pipefail
DISKS="\${SAS_DISKS:-$DISKS_ARG}"
POOL="\${SAS_POOL:-$POOL}"

names() {
  if [ -n "\$DISKS" ]; then
    printf '%s\n' \$DISKS
  elif [ -n "\$POOL" ] && command -v zpool >/dev/null 2>&1; then
    zpool status "\$POOL" 2>/dev/null | grep -oE "wwn-0x[0-9a-f]+" | sort -u | while read -r wwn; do
      basename "\$(readlink -f "/dev/disk/by-id/\$wwn" 2>/dev/null)" 2>/dev/null
    done
  else
    root_pk=\$(lsblk -no PKNAME "\$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null | head -1)
    for p in /sys/block/sd*; do
      [ -e "\$p" ] || continue
      n=\$(basename "\$p")
      [ "\$n" = "\${root_pk:-__none__}" ] && continue
      echo "\$n"
    done
  fi
}

names | sort -u | while read -r d; do
  { [ -z "\$d" ] || [ ! -e "/sys/block/\$d" ]; } && continue
  [ "\$(cat "/sys/block/\$d/queue/rotational" 2>/dev/null)" = "1" ] || continue
  sg=\$(basename "\$(readlink -f "/sys/block/\$d/device/generic" 2>/dev/null)" 2>/dev/null)
  { [ -n "\$sg" ] && [ -e "/dev/\$sg" ]; } && echo "\$d \$sg"
done
SH
  chmod +x /root/scripts/sas-disks.sh
}

if [ "$CHECK" = "1" ]; then
  step "Would manage: $MODE"
  if [ -x /root/scripts/sas-disks.sh ]; then
    /root/scripts/sas-disks.sh | while read -r d sg; do say "$d -> /dev/$sg"; done
  else
    say "(install first to resolve the list)"
  fi
  step "Components"
  for f in /root/scripts/sas-disks.sh /root/scripts/sas-spindown.sh \
           /root/scripts/sas-health-check.sh /root/scripts/spindown-drift-check.sh \
           /root/spindown-summary.sh \
           /etc/systemd/system/sas-spindown.service /etc/systemd/system/sas-spindown.timer; do
    [ -f "$f" ] && say "ok      $f" || say "MISSING $f"
  done
  step "Environment"
  for b in sg_start smartctl; do
    command -v "$b" >/dev/null 2>&1 && say "ok      $b" \
      || say "MISSING $b  (apt install sg3-utils smartmontools)"
  done
  command -v storcli  >/dev/null 2>&1 && say "ok      storcli" \
    || say "absent  storcli - disable controller patrol read yourself if it has one"
  command -v ipmitool >/dev/null 2>&1 && say "ok      ipmitool (watts logged as a bonus)" \
    || say "absent  ipmitool - sleep tracking still works, just without watts"
  exit 0
fi

step "Managing: $MODE"

step "Dependencies"
if ! command -v sg_start >/dev/null 2>&1 || ! command -v smartctl >/dev/null 2>&1; then
  apt-get install -y -qq sg3-utils smartmontools >/dev/null
fi
say "sg3-utils, smartmontools"

step "Disk list"
write_disk_list
N=$(/root/scripts/sas-disks.sh | wc -l)
[ "$N" -eq 0 ] && { echo "No rotational disks resolved. Set SAS_DISKS=\"sdb sdc\" explicitly." >&2; exit 1; }
say "$N disks"
/root/scripts/sas-disks.sh | while read -r d sg; do say "  $d -> /dev/$sg"; done

step "Spin-down enforcer"
cat > /root/scripts/sas-spindown.sh <<'SH'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Stateless spin-down enforcer. Every run re-reads each disk's real power state
# and decides from scratch: two consecutive runs with no I/O means park it.
# Nothing is remembered between runs, so a disk woken by anything - a web UI, a
# stray smartctl, something unidentified - is simply parked again next tick.
#
# CRITICAL: SCSI commands go to the *generic* device (/dev/sgN), never the
# block device (/dev/sdX). On /dev/sdX the drive genuinely stops, then the
# kernel revalidates on close and spins it straight back up - and nothing shows
# in /proc/diskstats, because it happens below the block layer.
set -uo pipefail
exec 9>/run/sas-spindown.lock
flock -n 9 || exit 0
STATE=/run/sas-spindown.state   # tmpfs - resets on reboot, by design
LOG=/var/log/spindown-history.log
declare -A prev idle
if [ -f "$STATE" ]; then
  while read -r d io n; do prev[$d]=$io; idle[$d]=$n; done < "$STATE"
fi
if ! mapfile -t DISKS < <(/root/scripts/sas-disks.sh) || [ "${#DISKS[@]}" -eq 0 ]; then
  logger -t sas-spindown "ERROR: no disks returned"; exit 1
fi
: > "$STATE.new"
to_sleep=(); asleep=0
for entry in "${DISKS[@]}"; do
  d=${entry%% *}; sg=${entry##* }
  io=$(awk -v d="$d" '$3==d {print $4"+"$8}' /proc/diskstats)
  [ -z "$io" ] && continue
  # Capture then match - never `cmd | grep -q` under `set -o pipefail`: grep
  # exits on the first match, the producer gets SIGPIPE and returns 141, and
  # the pipeline reports failure even though the match succeeded.
  pm=$(smartctl -i -n standby "/dev/$sg" 2>&1 || true)
  case "$pm" in
    *"Power mode is:"*ACTIVE*) ;;
    *) asleep=$((asleep+1)); echo "$d $io 0" >> "$STATE.new"; continue ;;
  esac
  n=0
  if [ "${prev[$d]:-}" = "$io" ]; then
    n=$(( ${idle[$d]:-0} + 1 ))
    if [ "$n" -ge 2 ]; then to_sleep+=("/dev/$sg:$d"); n=0; fi
  fi
  echo "$d $io $n" >> "$STATE.new"
done
mv "$STATE.new" "$STATE"
# Parallel: sg_start blocks ~9s per disk while the platter stops. Serially, the
# first disks get woken again before the last is even asked.
for entry in "${to_sleep[@]}"; do
  ( sg_start --pc=3 "${entry%%:*}" >/dev/null 2>&1 \
    && logger -t sas-spindown "parked: ${entry##*:}" ) &
done
wait
# Self-reported observability - no BMC or power meter required. This is what
# drift detection reads. Watts are appended only if a BMC happens to exist.
line="$(date '+%F %H:%M') asleep=$asleep/${#DISKS[@]}"
if command -v ipmitool >/dev/null 2>&1; then
  w=$(ipmitool dcmi power reading 2>/dev/null | awk '/Instantaneous/ {print $4}')
  [ -n "$w" ] && line="$line watts=$w"
fi
echo "$line" >> "$LOG"
SH
chmod +x /root/scripts/sas-spindown.sh

cat > /etc/systemd/system/sas-spindown.service <<'UNIT'
[Unit]
Description=Stateless SAS spin-down enforcer

[Service]
Type=oneshot
ExecStart=/root/scripts/sas-spindown.sh
UNIT
cat > /etc/systemd/system/sas-spindown.timer <<'UNIT'
[Unit]
Description=Run the SAS spin-down enforcer every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
say "enforcer + timer (5 min; disks park after ~10-15 min idle)"

step "Nightly health check"
cat > /root/scripts/sas-health-check.sh <<'SH'
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
[ -n "$ALERT" ] && echo -e "Disk health anomalies:$ALERT" | mail -s "Disk health alert ($(hostname))" root
echo "$(date '+%F %T') checked $((total-skipped))/$total (${skipped} asleep), alert='${ALERT:-none}'"
SH
chmod +x /root/scripts/sas-health-check.sh
say "SMART health, grown defects, uncorrected errors"

step "Nightly drift check"
cat > /root/scripts/spindown-drift-check.sh <<'SH'
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
  echo -e "Spin-down drift detected:$ALERT" | mail -s "Spin-down drift ($(hostname))" root
  echo "$(date '+%F %T') DRIFT:$ALERT"
else
  if [ "$pct" -lt 0 ]; then
    echo "$(date '+%F %T') ok (only ${n} samples in 24h - too few to judge yet)"
  else
    echo "$(date '+%F %T') ok (24h parked: ${pct}% of ${n} samples, baseline: $([ "$base" -ge 0 ] && echo "${base}%" || echo "building"))"
  fi
fi
SH
chmod +x /root/scripts/spindown-drift-check.sh
say "alerts on outright failure and on decay against your own baseline"

cat > /root/spindown-summary.sh <<'SH'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Status at a glance. Touches no disk, so it is safe to run at any time -
# querying a disk with smartctl would reset its idle count.
LOG=/var/log/spindown-history.log
window() {
  awk -v cut="$1" '
    { ts=substr($0,1,16)
      if (ts >= cut && match($0,/asleep=[0-9]+\/[0-9]+/)) { n++
          split(substr($0,RSTART+7,RLENGTH-7), a, "/")
          if (a[1]+0 == a[2]+0 && a[2]+0 > 0) c++ } }
    END { if (n>0) printf "%d/%d (%d%%)", c+0, n, (c+0)*100/n; else printf "no data yet" }' "$LOG" 2>/dev/null
}
echo "-- SPINDOWN $(date '+%d.%m %H:%M') --"
echo "now:          $(tail -1 "$LOG" 2>/dev/null | cut -d' ' -f3-)"
echo "last 2h:      $(window "$(date -d '-2 hours' '+%F %H:%M')")"
echo "last 24h:     $(window "$(date -d '-24 hours' '+%F %H:%M')")"
echo "since boot:   $(window "$(date -d "$(uptime -s)" '+%F %H:%M')")"
echo "parked (24h): $(journalctl -t sas-spindown --since '24 hours ago' 2>/dev/null | grep -c 'parked:' || true) commands"
SH
chmod +x /root/spindown-summary.sh

step "Controller and smartd"
if command -v storcli >/dev/null 2>&1; then
  storcli /c0 set patrolread=off >/dev/null 2>&1 && say "patrol read disabled" \
    || warn "could not disable patrol read - check 'storcli /c0 show patrolread'"
else
  warn "storcli absent: if your controller runs a patrol read, disable it or it wakes every disk on schedule"
fi

# smartd's '-n standby' power-mode skip is ATA-only. On SAS it polls anyway,
# wakes the drive and emits false FailedReadSmartSelfTestLog warnings. Exclude
# the spinning disks; sas-health-check.sh covers them instead.
if [ -f /etc/smartd.conf ] && ! grep -q "spin-down installer" /etc/smartd.conf; then
  cp /etc/smartd.conf "/etc/smartd.conf.bak-$(date +%F)"
  {
    echo "# Managed by the spin-down installer."
    echo "# Spinning disks are excluded on purpose: smartd's '-n standby' skip is"
    echo "# ATA-only, so on SAS it polls anyway, wakes the drive, and emits false"
    echo "# FailedReadSmartSelfTestLog warnings. Their health is covered nightly"
    echo "# by /root/scripts/sas-health-check.sh."
    echo "DEFAULT -m root -M exec /usr/share/smartmontools/smartd-runner"
    for dev in /sys/block/sd* /sys/block/nvme*; do
      [ -e "$dev" ] || continue
      d=$(basename "$dev")
      [ "$(cat "$dev/queue/rotational" 2>/dev/null)" = "0" ] || continue
      id=$(find /dev/disk/by-id -lname "*/$d" ! -name "*-part*" 2>/dev/null | grep -m1 "ata-\|nvme-" || true)
      [ -n "$id" ] && { case "$d" in nvme*) echo "$id" ;; *) echo "$id -d sat" ;; esac; }
    done
  } > /etc/smartd.conf
  systemctl restart smartmontools 2>/dev/null || true
  say "smartd limited to non-rotational devices (previous config kept alongside)"
else
  say "smartd.conf already managed - left as is"
fi

step "Nightly jobs"
cron_add() {
  crontab -l 2>/dev/null | grep -v "$2" | { cat; echo "$1 $2 >> $3 2>&1"; } | crontab -
  say "$1  $(basename "$2")"
}
cron_add "20 3 * * *" /root/scripts/sas-health-check.sh /var/log/sas-health.log
cron_add "25 3 * * *" /root/scripts/spindown-drift-check.sh /var/log/spindown-drift.log

step "Enabling"
systemctl daemon-reload
systemctl enable --now sas-spindown.timer >/dev/null 2>&1
say "sas-spindown.timer active"

step "Done"
say "Status:  /root/spindown-summary.sh"
say "Live:    journalctl -t sas-spindown -f"

step "FINDING WRITERS - the part no installer can do"
say "Disks only sleep if nothing writes to them. Check with:"
say ""
say "  grep -E ' sd[a-z]+ ' /proc/diskstats | awk '{print \$3, \$4+\$8}'; sleep 60"
say "  grep -E ' sd[a-z]+ ' /proc/diskstats | awk '{print \$3, \$4+\$8}'"
say ""
say "The two lists must match. If they do not, something is writing."
say "Usual suspects: media servers watching folders for changes, object"
say "stores with metadata heartbeats, indexers, anything syncing on a timer."
say "On ZFS also check 'tail /proc/spl/kstat/zfs/POOL/txgs' - commits carrying"
say "zero bytes still mean something is holding the pool dirty."
