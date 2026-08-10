#!/bin/bash
# SAS spin-down setup - idempotent installer.
#
# Brings a fresh Proxmox/Debian host to a working SAS spin-down state:
# enforcer, health check, drift alerting and observability. Safe to re-run;
# it rewrites the same files and never touches pool data.
#
#   ./install-spindown.sh                 # auto-detect the pool
#   SAS_POOL=tank ./install-spindown.sh   # or name it
#   ./install-spindown.sh --check         # show what would change, do nothing
#
# NOT handled here (site-specific, see the runbook): applications that keep
# writing to the pool. The installer sets up detection for them; silencing
# them is your job.
set -euo pipefail

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

say() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

# --- pool detection -----------------------------------------------------
# First pool with a rotational, wwn-addressed member. No `| head -1`: closing
# the pipe early sends SIGPIPE to the loop, which under `set -e -o pipefail`
# kills the script - the same trap the enforcer is written around.
detect_pool() {
  local p id d
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
[ -z "$POOL" ] && { echo "No pool with rotational members found. Set SAS_POOL=<name>." >&2; exit 1; }

step "Pool: $POOL"
mapfile -t MEMBERS < <(zpool status "$POOL" 2>/dev/null | grep -oE "wwn-0x[0-9a-f]+" | sort -u)
say "${#MEMBERS[@]} member IDs found"
[ "${#MEMBERS[@]}" -eq 0 ] && { echo "Pool has no wwn-addressed members - not a SAS/HBA layout." >&2; exit 1; }

if [ "$CHECK" = "1" ]; then
  step "Check mode - nothing will be written"
  for f in /root/scripts/sas-disks.sh /root/scripts/sas-spindown.sh \
           /root/scripts/sas-health-check.sh /root/scripts/spindown-drift-check.sh \
           /root/scripts/spindown-report.sh /root/spindown-summary.sh \
           /etc/systemd/system/sas-spindown.{service,timer} \
           /etc/systemd/system/spindown-report.{service,timer}; do
    [ -f "$f" ] && say "exists:  $f" || say "MISSING: $f"
  done
  say "patrol read: $(storcli /c0 show patrolread 2>/dev/null | grep -c 'PR Mode.*Disable' || echo 0) (1 = disabled)"
  say "smartd SAS:  $(journalctl -u smartmontools -b --no-pager 2>/dev/null | grep -c '0 SCSI/SAS' || echo 0) (1 = excluded)"
  exit 0
fi

# --- dependencies -------------------------------------------------------
step "Dependencies"
apt-get install -y -qq sg3-utils smartmontools >/dev/null
say "sg3-utils, smartmontools"

mkdir -p /root/scripts

PATHLINE='PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
PATHNOTE='# Explicit PATH: user crontabs get only /usr/bin:/bin, and smartctl/storcli/
# zpool live in /usr/sbin - without this they are silently not found and every
# check reports a false failure.'

# --- disk list ----------------------------------------------------------
step "Disk list (single source of truth)"
cat > /root/scripts/sas-disks.sh <<SH
#!/bin/bash
$PATHNOTE
$PATHLINE
# Prints "sdX sgN" per line for the pool's spinning members. Derived from the
# pool itself, so replacing a disk or moving a slot needs no edits. The
# rotational check means an SSD can never be selected.
set -uo pipefail
POOL="\${SAS_POOL:-$POOL}"
zpool status "\$POOL" 2>/dev/null | grep -oE "wwn-0x[0-9a-f]+" | sort -u | while read -r wwn; do
  d=\$(basename "\$(readlink -f "/dev/disk/by-id/\$wwn" 2>/dev/null)" 2>/dev/null)
  { [ -z "\$d" ] || [ ! -e "/sys/block/\$d" ]; } && continue
  [ "\$(cat "/sys/block/\$d/queue/rotational" 2>/dev/null)" = "1" ] || continue
  sg=\$(basename "\$(readlink -f "/sys/block/\$d/device/generic" 2>/dev/null)" 2>/dev/null)
  { [ -n "\$sg" ] && [ -e "/dev/\$sg" ]; } && echo "\$d \$sg"
done
SH
chmod +x /root/scripts/sas-disks.sh
say "$(/root/scripts/sas-disks.sh | wc -l) disks resolved"

# --- enforcer -----------------------------------------------------------
step "Spin-down enforcer"
cat > /root/scripts/sas-spindown.sh <<SH
#!/bin/bash
$PATHNOTE
$PATHLINE
# Stateless SAS spin-down enforcer.
#
# CRITICAL: SCSI commands go to the *generic* device (/dev/sgN), never the
# block device (/dev/sdX). On /dev/sdX the drive genuinely stops, then the
# kernel revalidates on close and spins it straight back up - and nothing
# appears in /proc/diskstats, because it all happens below the block layer.
set -uo pipefail
exec 9>/run/sas-spindown.lock
flock -n 9 || exit 0
STATE=/run/sas-spindown.state   # tmpfs - resets on reboot, by design
declare -A prev idle
if [ -f "\$STATE" ]; then
  while read -r d io n; do prev[\$d]=\$io; idle[\$d]=\$n; done < "\$STATE"
fi
if ! mapfile -t DISKS < <(/root/scripts/sas-disks.sh) || [ "\${#DISKS[@]}" -eq 0 ]; then
  logger -t sas-spindown "ERROR: no disks returned"; exit 1
fi
: > "\$STATE.new"
to_sleep=()
for entry in "\${DISKS[@]}"; do
  d=\${entry%% *}; sg=\${entry##* }
  io=\$(awk -v d="\$d" '\$3==d {print \$4"+"\$8}' /proc/diskstats)
  [ -z "\$io" ] && continue
  # Capture then match - never \`cmd | grep -q\` under \`set -o pipefail\`: grep
  # exits on first match, the producer gets SIGPIPE, and the pipeline reports
  # failure even though the match succeeded.
  pm=\$(smartctl -i -n standby "/dev/\$sg" 2>&1 || true)
  case "\$pm" in
    *"Power mode is:"*ACTIVE*) ;;
    *) echo "\$d \$io 0" >> "\$STATE.new"; continue ;;
  esac
  n=0
  if [ "\${prev[\$d]:-}" = "\$io" ]; then
    n=\$(( \${idle[\$d]:-0} + 1 ))
    if [ "\$n" -ge 2 ]; then to_sleep+=("/dev/\$sg:\$d"); n=0; fi
  fi
  echo "\$d \$io \$n" >> "\$STATE.new"
done
mv "\$STATE.new" "\$STATE"
# Parallel: sg_start blocks ~9s per disk; serially the first ones get woken
# again before the last is even asked.
for entry in "\${to_sleep[@]}"; do
  ( sg_start --pc=3 "\${entry%%:*}" >/dev/null 2>&1 \\
    && logger -t sas-spindown "standby issued: \${entry##*:}" ) &
done
wait
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
Description=Run SAS spin-down enforcer every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
say "script + timer (5 min)"

# --- observability ------------------------------------------------------
step "Observability"
cat > /root/scripts/spindown-report.sh <<SH
#!/bin/bash
$PATHNOTE
$PATHLINE
# Passive sample - touches NO disk. idrac= the averaged "Pwr Consumption"
# sensor (what the BMC UI shows, lags minutes); inst= DCMI instantaneous
# (responds at once, reads a few W higher on its own scale).
LOG=/var/log/spindown-history.log
IDRAC=\$(ipmitool sensor 2>/dev/null | grep -i "Pwr Consumption" | awk -F'|' '{print \$2}' | xargs | cut -d. -f1)
INST=\$(ipmitool dcmi power reading 2>/dev/null | awk '/Instantaneous/ {print \$4}')
IO=\$(/root/scripts/sas-disks.sh | awk '{print \$1}' | while read -r d; do
       awk -v d="\$d" '\$3==d {print \$4+\$8}' /proc/diskstats; done | paste -sd+ | bc 2>/dev/null)
SLEPT=\$(journalctl -t sas-spindown --since "-10min" 2>/dev/null | grep -c "standby issued" || true)
echo "\$(date '+%F %H:%M') idrac=\${IDRAC:-?}W inst=\${INST:-?}W io=\${IO:-?} standby_cmds=\${SLEPT:-0}" >> "\$LOG"
SH
chmod +x /root/scripts/spindown-report.sh

cat > /etc/systemd/system/spindown-report.service <<'UNIT'
[Unit]
Description=Passive spin-down observability sample

[Service]
Type=oneshot
ExecStart=/root/scripts/spindown-report.sh
UNIT
cat > /etc/systemd/system/spindown-report.timer <<'UNIT'
[Unit]
Description=Sample spin-down state every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
UNIT
say "sampler + timer (10 min)"

# --- health + drift -----------------------------------------------------
step "Health and drift checks"
cat > /root/scripts/sas-health-check.sh <<SH
#!/bin/bash
$PATHNOTE
$PATHLINE
# SMART health for disks smartd no longer watches. Runs nightly inside the
# backup window, when the disks are awake anyway; sleeping disks are skipped
# rather than woken, and "no data" is not treated as a fault.
set -uo pipefail
ALERT=""
skipped=0
while read -r d sg; do
  out=\$(smartctl -n standby -H -l error "/dev/\$sg" 2>&1)
  case "\$out" in *STANDBY*) skipped=\$((skipped+1)); continue ;; esac
  health=\$(echo "\$out" | grep -i "SMART Health Status" | awk -F: '{print \$2}' | xargs)
  defects=\$(smartctl -n standby -a "/dev/\$sg" 2>/dev/null | grep -i "grown defect" | grep -oE '[0-9]+\$')
  uncorr=\$(echo "\$out" | awk '/^read:|^write:|^verify:/ {print \$NF}' | awk '{s+=\$1} END {print s}')
  [ -n "\$health" ] && [ "\$health" != "OK" ] && ALERT="\$ALERT\\n\$d: health=\$health"
  [ "\${defects:-0}" -gt 0 ] && ALERT="\$ALERT\\n\$d: grown defects=\$defects"
  [ "\${uncorr:-0}" -gt 0 ] && ALERT="\$ALERT\\n\$d: uncorrected errors=\$uncorr"
done < <(/root/scripts/sas-disks.sh)
zerr=\$(zpool status $POOL | awk '/ONLINE|DEGRADED|FAULTED/ && \$3 ~ /[0-9]/ {if (\$3+\$4+\$5 > 0) print \$1": "\$3"/"\$4"/"\$5}')
[ -n "\$zerr" ] && ALERT="\$ALERT\\nzpool error counters:\\n\$zerr"
total=\$(/root/scripts/sas-disks.sh | wc -l)
if [ -n "\$ALERT" ]; then
  echo -e "SAS health anomalies:\$ALERT" | mail -s "SAS health alert (\$(hostname))" root
fi
echo "\$(date '+%F %T') checked \$((total-skipped))/\$total disks (\${skipped} asleep, skipped), alert='\${ALERT:-none}'"
SH
chmod +x /root/scripts/sas-health-check.sh

cat > /root/scripts/spindown-drift-check.sh <<SH
#!/bin/bash
$PATHNOTE
$PATHLINE
# Outcome-based drift detection: rather than checking each known waker is
# still silenced, ask whether the pool actually slept. That catches wakers
# nobody has thought of, and cannot rot the way a checklist does.
set -uo pipefail
LOG=/var/log/spindown-history.log
ALERT=""
ratio() {  # \$1 = from, \$2 = until (optional). Prints "pct samples", pct=-1 if too few.
  awk -v cut="\$1" -v until="\${2:-9999}" '
    { ts=substr(\$0,1,16)
      if (ts>=cut && ts<until) { n++
        if (match(\$0,/idrac=[0-9]+/)) { w=substr(\$0,RSTART+6,RLENGTH-6)+0
          if (w>0 && w<140) c++ } } }
    END { if (n>=6) printf "%d %d", (c+0)*100/n, n; else printf "-1 %d", n+0 }' "\$LOG" 2>/dev/null
}
read -r pct n <<< "\$(ratio "\$(date -d '-24 hours' '+%F %H:%M')")"
read -r base bn <<< "\$(ratio "\$(date -d '-8 days' '+%F %H:%M')" "\$(date -d '-24 hours' '+%F %H:%M')")"
if [ "\$pct" -ge 0 ] && [ "\$pct" -lt 30 ]; then
  ALERT="\$ALERT\\nPool asleep only \${pct}% of the last 24h (\${n} samples)."
elif [ "\$pct" -ge 0 ] && [ "\$base" -ge 0 ] && [ "\$base" -ge 50 ] \\
     && [ "\$pct" -lt \$(( base * 6 / 10 )) ]; then
  ALERT="\$ALERT\\nPool asleep \${pct}% of the last 24h, against a \${base}% baseline\\nover the previous 7 days. Something new is waking the disks."
fi
pr=\$(storcli /c0 show patrolread 2>/dev/null | grep -c "PR Mode.*Disable" || true)
[ "\${pr:-0}" -eq 0 ] && ALERT="\$ALERT\\nController patrol read is no longer disabled."
# grep -c, not grep -q: -q exits on first match, journalctl takes SIGPIPE and
# returns 141, which under pipefail reads as a failed check - a false alert.
smartd_sas=\$(journalctl -u smartmontools -b --no-pager 2>/dev/null | grep -c "0 SCSI/SAS" || true)
[ "\${smartd_sas:-0}" -eq 0 ] && ALERT="\$ALERT\\nsmartd is monitoring SAS disks again (should be SSD-only)."
systemctl is-active --quiet sas-spindown.timer || ALERT="\$ALERT\\nsas-spindown.timer is not active."
if [ -n "\$ALERT" ]; then
  echo -e "Spin-down drift detected:\$ALERT" | mail -s "Spin-down drift (\$(hostname))" root
  echo "\$(date '+%F %T') DRIFT:\$ALERT"
else
  echo "\$(date '+%F %T') ok (24h asleep: \${pct}% of \${n} samples, baseline \${base}%)"
fi
SH
chmod +x /root/scripts/spindown-drift-check.sh
say "health check + drift check"

# --- summary ------------------------------------------------------------
cat > /root/spindown-summary.sh <<SH
#!/bin/bash
$PATHLINE
# Phone-friendly status. Touches NO disk.
LOG=/var/log/spindown-history.log
now_i=\$(ipmitool sensor 2>/dev/null | grep -i "Pwr Consumption" | awk -F'|' '{print \$2}' | xargs | cut -d. -f1)
if [ "\${now_i:-999}" -lt 140 ]; then state="ASLEEP"; else state="AWAKE"; fi
window() {
  awk -v cut="\$1" '
    { ts=substr(\$0,1,16)
      if (ts >= cut) { n++
        if (match(\$0,/idrac=[0-9]+/)) { w=substr(\$0,RSTART+6,RLENGTH-6)+0
          if (w > 0 && w < 140) c++ } } }
    END { if (n>0) printf "%d/%d (%d%%)", c+0, n, (c+0)*100/n; else printf "no data yet" }' "\$LOG" 2>/dev/null
}
echo "-- SPINDOWN \$(date '+%d.%m %H:%M') --"
echo "now:        \$state (\$now_i W)"
echo "last 2h:    \$(window "\$(date -d '-2 hours' '+%F %H:%M')")"
echo "last 24h:   \$(window "\$(date -d '-24 hours' '+%F %H:%M')")"
echo "since boot: \$(window "\$(date -d "\$(uptime -s)" '+%F %H:%M')")"
echo "standby cmds (24h): \$(journalctl -t sas-spindown --since '24 hours ago' 2>/dev/null | grep -c 'standby issued' || true)"
echo "pool: \$(zpool status $POOL 2>/dev/null | grep -E '^ state:' | xargs)"
SH
chmod +x /root/spindown-summary.sh

# --- controller + smartd ------------------------------------------------
step "Controller and smartd"
if command -v storcli >/dev/null 2>&1; then
  storcli /c0 set patrolread=off >/dev/null 2>&1 && say "patrol read disabled"
else
  say "storcli not installed - disable patrol read manually if your controller has it"
fi

# smartd: keep watching non-rotational devices, drop the spinning ones. Derived,
# never hardcoded, so it stays correct on any host.
if [ -f /etc/smartd.conf ] && ! grep -q "spin-down installer" /etc/smartd.conf; then
  cp /etc/smartd.conf /etc/smartd.conf.bak-$(date +%F)
  {
    echo "# Managed by the spin-down installer. SAS/spinning disks are excluded:"
    echo "# smartd's -n standby power-mode skip is ATA-only, so on SAS it checks"
    echo "# anyway, wakes the drive and emits false FailedReadSmartSelfTestLog"
    echo "# warnings. Their health is covered by /root/scripts/sas-health-check.sh."
    echo "DEFAULT -m root -M exec /usr/share/smartmontools/smartd-runner"
    for dev in /sys/block/sd*; do
      d=$(basename "$dev")
      [ "$(cat "$dev/queue/rotational" 2>/dev/null)" = "0" ] || continue
      id=$(find /dev/disk/by-id -lname "*/$d" ! -name "*-part*" 2>/dev/null | grep -m1 "ata-\|nvme-" || true)
      [ -n "$id" ] && echo "$id -d sat"
    done
  } > /etc/smartd.conf
  systemctl restart smartmontools 2>/dev/null || true
  say "smartd limited to non-rotational devices (backup: /etc/smartd.conf.bak-$(date +%F))"
else
  say "smartd.conf already managed - left alone"
fi

# --- cron ---------------------------------------------------------------
step "Nightly jobs"
cron_add() {  # $1 = schedule, $2 = script, $3 = logfile
  crontab -l 2>/dev/null | grep -v "$2" | { cat; echo "$1 $2 >> $3 2>&1"; } | crontab -
  say "$1  $(basename "$2")"
}
cron_add "20 3 * * *" /root/scripts/sas-health-check.sh /var/log/sas-health.log
cron_add "25 3 * * *" /root/scripts/spindown-drift-check.sh /var/log/spindown-drift.log

# --- enable -------------------------------------------------------------
step "Enabling timers"
systemctl daemon-reload
systemctl enable --now sas-spindown.timer spindown-report.timer >/dev/null 2>&1
say "sas-spindown.timer, spindown-report.timer"

step "Done"
say "Disks will sleep after ~10-15 min of real idle."
say "Status:   /root/spindown-summary.sh"
say "Live log: journalctl -t sas-spindown -f"
echo
say "Next, and not automatable: find whatever still writes to the pool."
say "  grep -E ' sd[a-z]+ ' /proc/diskstats | awk '{print \$3, \$4+\$8}'; sleep 60; !!"
say "Counters must be identical. If not, hunt the writer - see the runbook."
