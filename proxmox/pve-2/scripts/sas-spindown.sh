#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Stateless SAS spin-down enforcer. One rule: when the POOL has moved zero bytes
# for two consecutive runs (~10 min), park every disk that is currently awake.
# Nothing is remembered between runs beyond that counter, so a disk woken by
# anything - a web UI, a stray smartctl, something unidentified - is simply
# parked again on the next quiet tick.
#
# CRITICAL: never decide per disk. `media` is 2x RAIDZ2-6, so one vdev can sit
# idle past any per-disk threshold while its sibling serves a read stream. The
# old per-disk rule parked those six mid-playback, and the next record landing
# on them woke all six at once. Each wake answers sense 2/04/01, megaraid_sas
# turns that into a *blocking* AEN poll (megasas_get_pd_list), and everything
# else on the H730P queues behind it - including the four rpool SSDs carrying
# the k8s control-plane VMs. etcd's fsync stalls on all three nodes at once.
# Measured 2026-08-16: 24 parks in one hour of streaming, 346 etcd fsyncs over
# 1s, 6-11 raft elections/day, one 122s hung-task trace. The pool is the unit of
# use; if it is quiet, every disk in it is quiet.
#
# CRITICAL: SCSI commands go to the *generic* device (/dev/sgN), never the block
# device (/dev/sdX). On /dev/sdX the drive genuinely stops, then the kernel
# revalidates on close and spins it straight back up - and nothing shows in
# /proc/diskstats, because it happens below the block layer.
set -uo pipefail
exec 9>/run/sas-spindown.lock
flock -n 9 || exit 0

STATE=/run/sas-spindown.state   # "<pool_bytes> <idle_runs>" - tmpfs, resets on reboot by design
LOG=/var/log/spindown-history.log
POOL="${SAS_POOL:-media}"

if ! mapfile -t DISKS < <(/root/scripts/sas-disks.sh) || [ "${#DISKS[@]}" -eq 0 ]; then
  logger -t sas-spindown "ERROR: no disks returned"; exit 1
fi

# objset kstats count dataset I/O including ARC hits, which is what we want: a
# stream served from cache still means the pool is in use, and the next miss
# would wake the platters.
io=$(awk '/^(nread|nwritten)/ {s+=$3} END {printf "%d", s}' \
     "/proc/spl/kstat/zfs/$POOL"/objset-* 2>/dev/null)

# A scrub or resilver traverses the pool directly, below the DMU, so it moves no
# objset counter at all - the gate above cannot see it and reads the pool as
# idle. Measured 2026-08-17: pool_idle climbed 14 -> 15 -> 16 straight through a
# running scrub while all 12 disks were awake, and the enforcer parked every one
# of them mid-scan. That is the same park/wake loop the pool-level rule exists to
# prevent, reached by a different route.
#
# Resilver is the more important half: parking disks during a rebuild extends the
# window where the pool has no redundancy left to lose.
#
# "paused" deliberately does not match - a paused scrub reads nothing, so parking
# is correct then. Capture then match, never `| grep -q` under pipefail.
scan=$(zpool status "$POOL" 2>/dev/null)
case "$scan" in
  *"scrub in progress"*|*"resilver in progress"*)
    echo "${io:-0} 0" > "$STATE"   # hold idle at 0 so the count restarts after
    exit 0 ;;
esac

prev=""; idle=0
[ -f "$STATE" ] && read -r prev idle < "$STATE"
# Unreadable counters, first run, or any movement at all resets the counter.
# Failing towards "disks keep spinning" costs watts; the other way costs etcd.
if [ -z "$io" ] || [ -z "$prev" ] || [ "$io" != "$prev" ]; then idle=0; else idle=$((idle+1)); fi
echo "${io:-0} $idle" > "$STATE"

awake=0; to_park=()
for entry in "${DISKS[@]}"; do
  d=${entry%% *}; sg=${entry##* }
  # Capture then match - never `cmd | grep -q` under `set -o pipefail`: grep
  # exits on the first match, the producer gets SIGPIPE and returns 141, and the
  # pipeline reports failure even though the match succeeded.
  # Awake only on an explicit ACTIVE; standby, timeout or error = leave alone.
  pm=$(smartctl -i -n standby "/dev/$sg" 2>&1 || true)
  case "$pm" in
    *"Power mode is:"*ACTIVE*)
      awake=$((awake+1))
      [ "$idle" -ge 2 ] && to_park+=("/dev/$sg:$d")
      ;;
  esac
done

# Parallel: sg_start blocks ~9s per disk while the platter stops. Serially, the
# first disks get woken again before the last is even asked.
for e in "${to_park[@]}"; do
  ( sg_start --pc=3 "${e%%:*}" >/dev/null 2>&1 \
    && logger -t sas-spindown "parked: ${e##*:}" ) &
done
wait

# Self-reported observability - no BMC or power meter required. This is what
# drift detection reads. Watts are appended only if a BMC happens to exist.
line="$(date '+%F %H:%M') asleep=$(( ${#DISKS[@]} - awake ))/${#DISKS[@]} pool_idle=$idle"
if command -v ipmitool >/dev/null 2>&1; then
  w=$(ipmitool dcmi power reading 2>/dev/null | awk '/Instantaneous/ {print $4}')
  [ -n "$w" ] && line="$line watts=$w"
fi
echo "$line" >> "$LOG"
