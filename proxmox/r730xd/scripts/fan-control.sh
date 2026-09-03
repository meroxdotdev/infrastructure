#!/bin/bash
# Hold the chassis fans near their floor while the box is idle, and hand
# cooling back to iDRAC before that stops being safe.
#
# WHY THIS EXISTS
#
# iDRAC's algorithm has no quiet setting left to give. `system.thermalsettings`
# is already at the minimum-cooling end of every knob it has: ThermalProfile
# "Minimum Power", FanSpeedOffset Off, MinimumFanSpeed unset,
# ThirdPartyPCIFanResponse Disabled, AirExhaustTemp 70. With all 16 drives
# reporting temperature and inlet at 27 C it still asks for ~3800 RPM, which
# is an honest answer to a 2U chassis with 12 spinning SAS drives in front of
# it - and far more air than this host needs while those drives are parked and
# the CPU sits at 41 C.
#
# Measured on this host, 2026-09-03, inlet 27 C, disks parked, CPU 41 C:
#
#   PWM   0%    1%    2%    4%    5%    8%   10%   12%   15%   iDRAC auto
#   RPM  1680  1740  2040  2400  2400  2900  3320  3600  4060   3720-3840
#
# So iDRAC's idle choice is about 12%, and the floor is 1680 RPM - less than
# half of it. Fan noise scales as 50*log10(rpm ratio), which makes 3840 -> 1680
# roughly -18 dB. Nothing else on this host moves the noise floor that far.
#
# Fourteen minutes at the floor, same conditions, is where the ceilings below
# come from. Everything settled and then stopped moving:
#
#   CPU     43 -> 48 C      hottest drive  34 -> 36 C  (parked)
#   ROC     63 -> 70 C      exhaust        35 -> 39 C
#
# The ROC plateaued at 70 C by minute nine and held it for the rest, which is
# the whole case for running this low: the hottest part of the chassis is 30 C
# under anything that would worry it, on half the air.
#
# WHAT IT COSTS
#
# Manual mode switches off the dynamic response, so this script has to be the
# response. It reads the four things worth reading - the CPU, the hottest drive,
# the PERC's ROC and the exhaust - climbs a small ladder of fixed speeds,
# and above the top of the ladder gives control back to iDRAC and leaves it
# there until the box is cool again. It also gives control back on an
# unreadable sensor, on a warm room, and on exit. The dumbest failure - this
# script dying - ends in Dell's algorithm, not in stuck fans.
#
# What is NOT covered: a hard host crash with the power still on leaves the
# fans wherever this left them. A dead host produces no heat, so that is
# accepted rather than solved. A cold boot or an iDRAC reset reverts to
# automatic on its own; the loop notices within one cycle and reapplies.
#
# Usage:
#   fan-control.sh            # the loop, run by fan-control.service
#   fan-control.sh --status   # one-shot: sensors, and what a cold start would
#                             # pick. Not the running rung - the loop carries
#                             # hysteresis and this does not. The RPM it prints
#                             # underneath is the live truth; the journal has
#                             # the transitions.
#   fan-control.sh --restore  # hand cooling back to iDRAC and exit
#
# TESTED ON: Dell R730xd, iDRAC8 firmware 2.84, PERC H730P, Proxmox 9. The raw
# IPMI commands exist on iDRAC 6/7/8 and on iDRAC 9 up to 3.30.30.30; Dell
# removed them from 3.34.34.34 onward, so this does not carry to 14G.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -uo pipefail

INTERVAL=30          # seconds between decisions
INLET_MAX=32         # a room this warm is iDRAC's problem, not this script's
HYST=4               # degrees below a step's ceiling before dropping back down

# Each rung: the CPU ceiling, the hottest-drive ceiling, the PERC ROC ceiling,
# the exhaust ceiling, and the fan percent to hold while under all four. Past
# the last rung the ladder ends and iDRAC takes over.
#
# Four sensors and not just the CPU, because on this box the CPU is the least
# of it. The drives are what front-to-back airflow in a 2U chassis is actually
# there to cool, and the H730P's ROC is the part that runs hottest of all: 61 C
# with the fans at 3800 RPM, against a 55 C rating on the drives and a 41 C
# CPU. Ceilings are set with room to spare - the drives are good to 55 C and
# the ROC throttles around 100 C - because the point of a rung is to react
# early, not to sit at the limit.
#
# Exhaust is the catch-all, and it is in the ladder for the things there is no
# sensor for: VRMs, RAM, the idle Quadro. Whatever heats up in this chassis,
# its heat leaves through the same hole, so exhaust rising is the one symptom
# nothing can hide from. Measured 39 C at the floor; Dell's own limit for it,
# AirExhaustTemp, is 70.
#
# The drive ceilings are deliberately not tight around the 36 C measured with
# the pool parked. Spinning twelve SAS drives up for a backup or a scrub is
# worth several degrees on its own, and iDRAC accepts that without ramping;
# reacting to it at 37 C would make this louder than the algorithm it replaced,
# which is a strange way to lose.
STEPS=(
  "55 42 78 50  0"
  "62 46 84 55  8"
  "68 49 88 60 16"
  "73 52 92 65 28"
)

say() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

ipmi_auto()   { ipmitool raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1; }
ipmi_manual() { ipmitool raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1; }
ipmi_pwm()    { ipmitool raw 0x30 0x30 0x02 0xff "$(printf '0x%02x' "$1")" >/dev/null 2>&1; }

# All three IPMI temperatures in one call. Sensor IDs rather than names: this
# chassis has two sensors called "Temp" and the second one is a disabled CPU2.
#   04h = Inlet, 01h = Exhaust, 0Eh = CPU1
#
# Every sensor read is wrapped in `timeout`. A command that returns an error is
# handled - it ends in iDRAC's algorithm. A command that hangs forever is not:
# the loop would stop deciding while the fans stayed where they were, and
# systemd cannot tell a wedged process from a busy one. Ten seconds is roughly
# five times the slowest honest reading seen here.
read_ipmi_temps() {
  local out
  out=$(timeout 10 ipmitool sdr type temperature 2>/dev/null) || return 1
  INLET=$(awk   -F'|' '$2 ~ /04h/ {gsub(/[^0-9]/,"",$5); print $5+0; exit}' <<<"$out")
  EXHAUST=$(awk -F'|' '$2 ~ /01h/ {gsub(/[^0-9]/,"",$5); print $5+0; exit}' <<<"$out")
  CPU=$(awk     -F'|' '$2 ~ /0Eh/ {gsub(/[^0-9]/,"",$5); print $5+0; exit}' <<<"$out")
  [ -n "${INLET:-}" ] && [ -n "${CPU:-}" ] && [ -n "${EXHAUST:-}" ] &&
    [ "$CPU" -gt 0 ] && [ "$INLET" -gt 0 ] && [ "$EXHAUST" -gt 0 ]
}

# The hottest drive, and the controller itself. Both come from the PERC, which
# already holds the values - verified on 2026-09-03 that polling them every
# 30 s does not wake a parked drive (spindown-history.log stayed at
# asleep=12/12 throughout). Do not swap this for smartctl: on SAS that spins
# the platters up, see install-spindown.sh.
read_storcli_temps() {
  DRIVE=$(timeout 10 storcli /c0/eall/sall show all 2>/dev/null |
    awk '/Drive Temperature/ {gsub(/C/,"",$4); if ($4+0 > m) m = $4+0} END {print m+0}')
  ROC=$(timeout 10 storcli /c0 show temperature 2>/dev/null | awk '/ROC temperature/ {print $4+0}')
  [ -n "${DRIVE:-}" ] && [ "$DRIVE" -gt 0 ] && [ -n "${ROC:-}" ] && [ "$ROC" -gt 0 ]
}

read_all() { read_ipmi_temps && read_storcli_temps; }

# Where the current temperatures put us on the ladder. Climbing is immediate;
# coming down needs HYST degrees of margin, so a load that hovers on a
# threshold does not make the fans breathe in and out.
pick_step() {
  local c d r x
  while [ "$STEP" -gt 0 ]; do
    read -r c d r x _ <<<"${STEPS[$((STEP - 1))]}"
    [ "$CPU" -le $((c - HYST)) ] && [ "$DRIVE" -le $((d - HYST)) ] &&
      [ "$ROC" -le $((r - HYST)) ] && [ "$EXHAUST" -le $((x - HYST)) ] || break
    STEP=$((STEP - 1))
  done
  while [ "$STEP" -lt "${#STEPS[@]}" ]; do
    read -r c d r x _ <<<"${STEPS[$STEP]}"
    [ "$CPU" -gt "$c" ] || [ "$DRIVE" -gt "$d" ] || [ "$ROC" -gt "$r" ] ||
      [ "$EXHAUST" -gt "$x" ] || break
    STEP=$((STEP + 1))
  done
}

status_line() {
  printf 'cpu=%sC drive=%sC roc=%sC exhaust=%sC inlet=%sC -> %s' \
    "$CPU" "$DRIVE" "$ROC" "$EXHAUST" "$INLET" "$1"
}

case "${1:-}" in
  --restore)
    ipmi_auto && echo "cooling handed back to iDRAC" || { echo "ipmitool failed"; exit 1; }
    exit 0
    ;;
  --status)
    # Deliberately stateless: it answers "what do the temperatures ask for", not
    # "what is the loop doing". The fan RPM printed below answers the second.
    read_all || { echo "sensors unreadable"; exit 1; }
    STEP=0; pick_step
    if [ "$STEP" -ge "${#STEPS[@]}" ] || [ "$INLET" -gt "$INLET_MAX" ]; then
      status_line "iDRAC automatic"
    else
      read -r _ _ _ _ p <<<"${STEPS[$STEP]}"
      status_line "${p}% manual"
    fi
    echo
    ipmitool sdr type fan 2>/dev/null | awk -F'|' '/Fan[0-9] RPM/ {gsub(/^ +| +$/,"",$1); gsub(/^ +/,"",$5); print "  " $1 " " $5}'
    exit 0
    ;;
esac

trap 'ipmi_auto; say "stopping - cooling handed back to iDRAC"; exit 0' INT TERM
trap 'ipmi_auto' EXIT

STEP=0
LAST=""          # last applied state, so the log records changes and not ticks
say "started (interval ${INTERVAL}s, ladder ${#STEPS[@]} rungs, inlet limit ${INLET_MAX}C)"

while :; do
  if ! read_all; then
    [ "$LAST" != "auto:sensors" ] && say "sensors unreadable - iDRAC automatic"
    LAST="auto:sensors"
    ipmi_auto
  else
    pick_step
    if [ "$STEP" -ge "${#STEPS[@]}" ]; then
      [ "$LAST" != "auto:hot" ] && say "$(status_line 'iDRAC automatic - above the ladder')"
      LAST="auto:hot"
      ipmi_auto
    elif [ "$INLET" -gt "$INLET_MAX" ]; then
      [ "$LAST" != "auto:inlet" ] && say "$(status_line "iDRAC automatic - inlet above ${INLET_MAX}C")"
      LAST="auto:inlet"
      ipmi_auto
    else
      read -r _ _ _ _ pwm <<<"${STEPS[$STEP]}"
      [ "$LAST" != "manual:$pwm" ] && say "$(status_line "${pwm}% manual")"
      LAST="manual:$pwm"
      # Reapplied every cycle on purpose: an iDRAC reset silently drops back to
      # automatic, and this is what puts it back without anyone noticing.
      ipmi_manual
      ipmi_pwm "$pwm"
    fi
  fi
  # Tell systemd the loop is still deciding. WatchdogSec in the unit turns a
  # missing ping into a restart, and a restart runs ExecStopPost, which hands
  # cooling back to iDRAC. That closes the one hole `Restart=always` does not
  # cover: a process that is wedged rather than dead.
  [ -n "${WATCHDOG_USEC:-}" ] && systemd-notify WATCHDOG=1 2>/dev/null
  sleep "$INTERVAL"
done
