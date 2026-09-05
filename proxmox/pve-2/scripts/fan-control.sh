#!/bin/bash
# Hold the chassis fans near their floor while the box is idle, and hand
# cooling back to iDRAC before that stops being safe.
#
# WHY: iDRAC has no quieter setting left. Every knob in
# `system.thermalsettings` is at its minimum-cooling position and it still asks
# for ~3800 RPM with the pool parked and the CPU at 41 C. MinimumFanSpeed is a
# floor, not a ceiling; nothing supported asks for less air.
#
# Measured 2026-09-03, inlet 27 C, disks parked:
#
#   PWM   0%    1%    2%    4%    5%    8%   10%   12%   15%   iDRAC auto
#   RPM  1680  1740  2040  2400  2400  2900  3320  3600  4060   3720-3840
#
# iDRAC's idle choice is ~12%; the floor is 1680 RPM. Noise goes as
# 50*log10(rpm ratio), so 3840 -> 1680 is about -18 dB.
#
# 14 minutes at 1680 RPM, where the ceilings below come from - everything
# settled and stopped: CPU 43->48, hottest drive 34->36 (parked), exhaust
# 35->39, ROC 63->70 with a plateau at minute nine. The plateau is the
# evidence: heat in equals heat out, 30 C under anything that would worry it.
#
# THOSE NUMBERS ARE FROM AN IDLE HOST AND THE HOST STOPPED BEING IDLE THE NEXT
# DAY. On 2026-09-04 `kubernetes-2` (VM 811) landed here, and the CPU baseline
# rose about 8 C with it. Re-measured 2026-09-05, same inlet, pool still
# parked, and the two fan states are now:
#
#   1680 RPM  ->  CPU 56, ROC 71, drive 38, exhaust 41
#   2900 RPM  ->  CPU 51, ROC 63, drive 38, exhaust 40
#
# Read that carefully: the 5 C on the CPU and the 8 C on the ROC are not load,
# they are the fan change itself. Each speed has its own equilibrium, and the
# ladder decides which one the box sits at. So a ceiling placed *between* two
# equilibria has no stable side - the box crosses it going up, the extra air
# pulls it back under, and it crosses again. A limit cycle, not a thermal
# event.
#
# That is exactly what the original CPU ceiling of 55 became once the baseline
# moved: 117 drops to 0% against 118 climbs to 8% in a single day, every one of
# them at cpu=56 up and cpu=51 down. Fans breathing in and out every five to
# ten minutes, which is worse to live with than the constant 2900 it was
# replacing. The CPU column was raised on 2026-09-05 to clear the 1680 RPM
# equilibrium instead of splitting it.
#
# The rule this leaves behind: a ceiling must sit above the temperature its own
# rung settles at, not between the rungs. If a node is ever added to or removed
# from this host, re-measure both equilibria before trusting the ladder.
#
# COST: manual mode has no dynamic response, so this script is the response.
# It reads CPU, hottest drive, PERC ROC and exhaust, climbs the ladder below,
# and returns cooling to iDRAC above the top rung, above INLET_MAX, on an
# unreadable sensor and on exit. Every failure ends in Dell's algorithm.
#
# NOT covered: a host that dies with the power on leaves the fans where this
# left them. A dead host makes no heat. A cold boot or an iDRAC reset reverts
# to automatic on its own; the loop reapplies within one cycle.
#
# Usage:
#   fan-control.sh            # the loop, run by fan-control.service
#   fan-control.sh --status   # sensors + live RPM. Stateless: it shows what a
#                             # cold start would pick, not the running rung.
#                             # The journal has the transitions.
#   fan-control.sh --restore  # hand cooling back to iDRAC and exit
#
# TESTED ON: R730xd, iDRAC8 fw 2.84, PERC H730P, Proxmox 9. The raw commands
# exist on iDRAC 6/7/8 and iDRAC 9 up to 3.30.30.30; Dell removed them from
# 3.34.34.34 on, so this does not carry to 14G.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -uo pipefail

INTERVAL=30          # seconds between decisions
INLET_MAX=32         # a room this warm is iDRAC's problem, not this script's
HYST=4               # degrees below a step's ceiling before dropping back down

# Rungs: CPU ceiling, hottest-drive ceiling, PERC ROC ceiling, exhaust ceiling,
# fan percent. Past the last rung, iDRAC takes over.
#
# Four sensors because the CPU is the least of it here. The drives are what a
# 2U's airflow is there to cool, and the ROC is the hottest part in the chassis
# - 61 C while the CPU sits at 41. Exhaust is the catch-all for what has no
# sensor: VRMs, RAM, the idle Quadro. Limits: drives 55 C, ROC ~100 C throttle,
# AirExhaustTemp 70 C. Ceilings sit well under those, to react early.
#
# Drive ceilings are deliberately loose around the 36 C measured with the pool
# parked: spinning twelve SAS drives up for a backup is worth several degrees,
# and iDRAC accepts that without ramping. Reacting at 37 C would make this
# louder than what it replaced.
#
# The CPU column carries +5 over the original 2026-09-03 values (55/62/68/73),
# raised 2026-09-05 to clear the post-kubernetes-2 baseline - see the limit
# cycle described in the header. Rung 0 at 60 sits 4 C above where 1680 RPM
# settles (56), and coming back down needs 60-HYST = 56, which 2900 RPM
# comfortably reaches at 51. Both directions have margin now.
#
# The other three columns are untouched: they were never the ones triggering.
# ROC swings 63-71 against 78 and the drives sat at 38 against 42 all day, and
# the four escalations to 16% on 2026-09-05 were a genuine spin-up (drive 48).
# The top rung stays under this Xeon's ~76 C Tcase; above it iDRAC takes over.
STEPS=(
  "60 42 78 50  0"
  "66 46 84 55  8"
  "70 49 88 60 16"
  "74 52 92 65 28"
)

say() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

ipmi_auto()   { ipmitool raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1; }
ipmi_manual() { ipmitool raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1; }
ipmi_pwm()    { ipmitool raw 0x30 0x30 0x02 0xff "$(printf '0x%02x' "$1")" >/dev/null 2>&1; }

# All three IPMI temperatures in one call. Sensor IDs rather than names: this
# chassis has two sensors called "Temp" and the second one is a disabled CPU2.
#   04h = Inlet, 01h = Exhaust, 0Eh = CPU1
#
# Reads are wrapped in `timeout`: an error is handled and ends in iDRAC's
# algorithm, but a hang is not - the loop would stop deciding while the fans
# stayed put, and systemd cannot tell a wedged process from a busy one.
read_ipmi_temps() {
  local out
  out=$(timeout 10 ipmitool sdr type temperature 2>/dev/null) || return 1
  INLET=$(awk   -F'|' '$2 ~ /04h/ {gsub(/[^0-9]/,"",$5); print $5+0; exit}' <<<"$out")
  EXHAUST=$(awk -F'|' '$2 ~ /01h/ {gsub(/[^0-9]/,"",$5); print $5+0; exit}' <<<"$out")
  CPU=$(awk     -F'|' '$2 ~ /0Eh/ {gsub(/[^0-9]/,"",$5); print $5+0; exit}' <<<"$out")
  [ -n "${INLET:-}" ] && [ -n "${CPU:-}" ] && [ -n "${EXHAUST:-}" ] &&
    [ "$CPU" -gt 0 ] && [ "$INLET" -gt 0 ] && [ "$EXHAUST" -gt 0 ]
}

# Both come from the PERC, which already holds them - verified 2026-09-03 that
# polling every 30 s does not wake a parked drive (spindown-history.log stayed
# at asleep=12/12). Do not swap for smartctl: on SAS that spins the platters
# up, see install-spindown.sh.
read_storcli_temps() {
  DRIVE=$(timeout 10 storcli /c0/eall/sall show all 2>/dev/null |
    awk '/Drive Temperature/ {gsub(/C/,"",$4); if ($4+0 > m) m = $4+0} END {print m+0}')
  ROC=$(timeout 10 storcli /c0 show temperature 2>/dev/null | awk '/ROC temperature/ {print $4+0}')
  [ -n "${DRIVE:-}" ] && [ "$DRIVE" -gt 0 ] && [ -n "${ROC:-}" ] && [ "$ROC" -gt 0 ]
}

read_all() { read_ipmi_temps && read_storcli_temps; }

# Climbing is immediate on any one sensor; coming down needs HYST degrees of
# margin on all four, so a load hovering on a threshold does not make the fans
# breathe in and out.
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
  # WatchdogSec turns a missing ping into a restart, and a restart runs
  # ExecStopPost, which hands cooling back to iDRAC. Closes the one hole
  # Restart=always misses: a process wedged rather than dead.
  [ -n "${WATCHDOG_USEC:-}" ] && systemd-notify WATCHDOG=1 2>/dev/null
  sleep "$INTERVAL"
done
