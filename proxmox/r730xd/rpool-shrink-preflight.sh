#!/bin/bash
# rpool 4-disk RAID10 -> 2-disk mirror: read-only pre-flight.
#
# Answers one question: can one mirror vdev be evacuated from rpool with
# `zpool remove`, and which two physical slots do the freed SSDs sit in.
# Changes nothing - no zpool, no zfs, no storcli write commands.
#
#   ./rpool-shrink-preflight.sh            # report, gates, slot map
#   RPOOL=tank ./rpool-shrink-preflight.sh
#
# Runbook: rpool-shrink.md. Run this first; every gate must read GO.
#
# TESTED ON: Dell R730xd, PERC H730P in HBA mode, Proxmox 9, rpool = 2x
# mirror of 960GB Intel SATA SSDs. Slot mapping needs storcli; without it
# the report still lands, minus the EID:Slot column.
set -uo pipefail

POOL="${RPOOL:-rpool}"
STORCLI=$(command -v storcli64 || command -v storcli || true)

# The SES enclosure device drives the locate LEDs. storcli's own
# `start locate` fails while the drives are in JBOD - the controller does not
# own their enclosure services - so the backplane is asked directly.
find_ses() {
  local s
  command -v sg_ses >/dev/null 2>&1 || return 0
  for s in /dev/sg*; do
    if sg_ses -p 7 "$s" 2>/dev/null | grep -q "Drive Slot 0"; then echo "$s"; return 0; fi
  done
}
SES=$(find_ses)
GATES_FAILED=0

say()  { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
gate() { # gate GO|NO-GO|WARN "text"
  case "$1" in
    GO)    printf '  [ GO    ] %s\n' "$2" ;;
    WARN)  printf '  [ WARN  ] %s\n' "$2" ;;
    *)     printf '  [ NO-GO ] %s\n' "$2"; GATES_FAILED=$((GATES_FAILED+1)) ;;
  esac
}
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"; }

command -v zpool >/dev/null || { echo "no zpool on this host" >&2; exit 1; }
zpool list "$POOL" >/dev/null 2>&1 || { echo "pool '$POOL' not found" >&2; exit 1; }

step "Topology"
zpool status "$POOL"

# ---------------------------------------------------------------- gates ----
step "Gates"

# 1. Only mirrors. raidz/draid top-level vdevs cannot be removed, and their
#    presence blocks removal of any other vdev in the same pool.
if zpool status "$POOL" | grep -qE '^\s+(raidz|draid)'; then
  gate NO-GO "pool contains a raidz/draid vdev - device removal is refused"
else
  gate GO "all data vdevs are mirrors"
fi

# 2. Two mirrors, no more, no less. One is nothing to shrink; three means
#    picking which, and this script does not.
MIRRORS=$(zpool list -vHp "$POOL" | awk '$1 ~ /^mirror-/ {print $1}')
NMIR=$(printf '%s\n' "$MIRRORS" | grep -c . || true)
if [ "$NMIR" -eq 2 ]; then
  gate GO "2 mirror vdevs - one can go"
else
  gate NO-GO "$NMIR mirror vdevs, expected 2 (topology changed - re-read the runbook)"
fi

# 3. device_removal. Enabled is enough; it flips to active on first removal.
DEVREM=$(zpool get -H -o value feature@device_removal "$POOL" 2>/dev/null || echo missing)
case "$DEVREM" in
  enabled|active) gate GO "feature@device_removal = $DEVREM" ;;
  *)              gate NO-GO "feature@device_removal = $DEVREM" ;;
esac

# 4. Uniform ashift. Removal refuses to map blocks onto a vdev with a larger
#    ashift than the one being evacuated.
ASHIFTS=$(zdb -C "$POOL" 2>/dev/null | grep -oE "ashift: [0-9]+" | awk '{print $2}' | sort -u)
NASH=$(printf '%s\n' "$ASHIFTS" | grep -c . || true)
if [ "$NASH" -eq 1 ]; then
  gate GO "ashift uniform ($ASHIFTS)"
else
  gate NO-GO "mixed ashift ($(echo $ASHIFTS | tr '\n' ' ')) - removal will refuse"
fi

# 5. Nothing else already walking the pool.
if zpool status "$POOL" | grep -qE 'scrub in progress|resilver in progress|removal in progress'; then
  gate NO-GO "scrub/resilver/removal running - wait for it, or pause the scrub"
else
  gate GO "no scrub, resilver or removal in progress"
fi

# 6. A pool checkpoint pins the old topology and blocks removal outright.
if zpool status "$POOL" | grep -q 'checkpoint'; then
  gate NO-GO "pool checkpoint exists - discard it first (zpool checkpoint -d)"
else
  gate GO "no pool checkpoint"
fi

# 7. log/cache/spare devices. Not fatal, but they must be removed separately
#    and this script does not plan for them.
if zpool status "$POOL" | grep -qE '^\s+(logs|cache|spares|special|dedup)'; then
  gate WARN "pool has log/cache/spare/special/dedup devices - handle them separately"
else
  gate GO "no log/cache/spare/special/dedup devices"
fi

# ------------------------------------------------------------- capacity ----
step "Capacity"

read -r P_SIZE P_ALLOC P_FREE P_FRAG < <(zpool list -Hp -o size,alloc,free,frag "$POOL")
say "pool     size $(human "$P_SIZE")  alloc $(human "$P_ALLOC")  free $(human "$P_FREE")  frag ${P_FRAG}%"

SMALLEST=""; SMALLEST_SZ=0; SURVIVOR_SZ=0
while read -r NAME SZ ALLOC FREE; do
  [ -z "${NAME:-}" ] && continue
  say "$NAME  size $(human "$SZ")  alloc $(human "$ALLOC")  free $(human "$FREE")"
  if [ -z "$SMALLEST" ] || [ "$SZ" -lt "$SMALLEST_SZ" ]; then
    [ -n "$SMALLEST" ] && SURVIVOR_SZ=$SMALLEST_SZ
    SMALLEST=$NAME; SMALLEST_SZ=$SZ
  else
    SURVIVOR_SZ=$SZ
  fi
done < <(zpool list -vHp "$POOL" | awk '$1 ~ /^mirror-/ {print $1, $2, $3, $4}')

if [ "$SURVIVOR_SZ" -gt 0 ]; then
  # Everything allocated pool-wide has to land on the surviving mirror.
  PCT=$(( P_ALLOC * 100 / SURVIVOR_SZ ))
  say ""
  say "after removal: $(human "$P_ALLOC") on a $(human "$SURVIVOR_SZ") mirror = ${PCT}% full"
  if   [ "$PCT" -ge 80 ]; then gate NO-GO "${PCT}% - does not fit with room to work; free space first"
  elif [ "$PCT" -ge 65 ]; then gate WARN  "${PCT}% - fits, but ZFS write performance degrades past ~80%"
  else                         gate GO    "${PCT}% - fits comfortably"
  fi
fi

# Thin zvols can overcommit a pool that is half this size. Worth seeing.
VOLSUM=$(zfs list -Hp -o volsize -t volume -r "$POOL" 2>/dev/null | awk '{s+=$1} END{print s+0}')
if [ "${VOLSUM:-0}" -gt 0 ] && [ "$SURVIVOR_SZ" -gt 0 ]; then
  say "thin zvol volsize committed: $(human "$VOLSUM") against a $(human "$SURVIVOR_SZ") mirror"
  [ "$VOLSUM" -gt "$SURVIVOR_SZ" ] && \
    gate WARN "zvols are overcommitted after the shrink - a full-write of every zvol would ENOSPC"
fi

# ----------------------------------------------------------------- boot ----
step "Boot (ESP redundancy)"
if command -v proxmox-boot-tool >/dev/null 2>&1; then
  proxmox-boot-tool status 2>&1 | sed 's/^/  /'
  NESP=$(proxmox-boot-tool status 2>/dev/null | grep -cE '^[0-9A-F]{4}-[0-9A-F]{4}' || true)
  if [ "${NESP:-0}" -ge 3 ]; then
    gate GO "$NESP ESPs registered - 2 survive the pull"
  else
    gate WARN "$NESP ESPs registered - confirm both surviving disks are listed before pulling anything"
  fi
else
  gate WARN "proxmox-boot-tool absent - verify bootloader redundancy by hand"
fi

# ------------------------------------------------------------- physical ----
step "Physical map"
say "The two disks to pull are the members of the mirror you remove."
say ""

slot_of() { # slot_of SERIAL -> "eID:slot"
  [ -z "$STORCLI" ] && return 0
  "$STORCLI" /c0/eall/sall show all 2>/dev/null | awk -v sn="$1" '
    /^Drive \/c0\/e/ { split($2, a, "/"); dr = a[3] ":" a[4]; sub(/^e/, "", dr); sub(/s/, "", dr) }
    /SN =/ { s=$3; if (s == sn) { print dr; exit } }'
}

for MIR in $MIRRORS; do
  printf '\n  --- %s\n' "$MIR"
  # Members of this mirror, as the pool names them.
  MEMBERS=$(zpool status -P "$POOL" | awk -v m="$MIR" '
    $1 == m {inblock=1; next}
    inblock && $1 ~ /^mirror-/ {inblock=0}
    inblock && $1 ~ /^\// {print $1}')
  for DEV in $MEMBERS; do
    NODE=$(readlink -f "$DEV")
    DISK=$(lsblk -no pkname "$NODE" 2>/dev/null | head -1)
    [ -z "$DISK" ] && { BASE=$(basename "$NODE"); DISK=${BASE%%[0-9]*}; }
    SN=$(smartctl -i "/dev/$DISK" 2>/dev/null | awk -F: '/Serial Number/{gsub(/ /,"",$2); print $2}')
    MODEL=$(smartctl -i "/dev/$DISK" 2>/dev/null | awk -F: '/Device Model|Model Number/{sub(/^ +/,"",$2); print $2; exit}')
    WEAR=$(smartctl -A "/dev/$DISK" 2>/dev/null | awk '/Media_Wearout_Indicator|Percentage Used/{print $4" "$10; exit}')
    SLOT=$(slot_of "$SN")
    printf '  %-14s %-22s SN %-18s %s\n' "/dev/$DISK" "${MODEL:-?}" "${SN:-?}" "${SLOT:+slot $SLOT}"
    [ -n "${WEAR:-}" ] && printf '  %-14s wear/life: %s\n' "" "$WEAR"
    if [ -n "$SLOT" ] && [ -n "$SES" ]; then
      printf '  %-14s locate LED: sg_ses --dev-slot-num=%s --set=ident %s\n' \
        "" "${SLOT##*:}" "$SES"
    elif [ -n "$SLOT" ]; then
      printf '  %-14s locate LED: no sg_ses/SES device found - blink from iDRAC\n' ""
    fi
  done
done

step "Verdict"
if [ "$GATES_FAILED" -eq 0 ]; then
  say "All gates GO. Removal command (pick the mirror you mapped above):"
  say ""
  say "    zpool remove $POOL <mirror-N>"
  say ""
  say "Read rpool-shrink.md before running it - removal is irreversible,"
  say "and the disks must stay in the chassis until it finishes."
else
  say "$GATES_FAILED gate(s) NO-GO. Do not run zpool remove."
fi
exit "$GATES_FAILED"
