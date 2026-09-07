#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin, while smartctl, storcli
# and zpool live in /usr/sbin. Without this they are silently not found and
# every check reports a false failure.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Prints "sdX sgN" per line for the disks to manage. Re-derived on every run,
# so replacing a disk or moving a slot needs no edits. Non-rotational devices
# are filtered out last, whichever source was used - an SSD can never appear.
set -uo pipefail
DISKS="${SAS_DISKS:-}"
POOL="${SAS_POOL:-media}"

names() {
  if [ -n "$DISKS" ]; then
    printf '%s\n' $DISKS
  elif [ -n "$POOL" ] && command -v zpool >/dev/null 2>&1; then
    zpool status "$POOL" 2>/dev/null | grep -oE "wwn-0x[0-9a-f]+" | sort -u | while read -r wwn; do
      basename "$(readlink -f "/dev/disk/by-id/$wwn" 2>/dev/null)" 2>/dev/null
    done
  else
    root_pk=$(lsblk -no PKNAME "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null | head -1)
    for p in /sys/block/sd*; do
      [ -e "$p" ] || continue
      n=$(basename "$p")
      [ "$n" = "${root_pk:-__none__}" ] && continue
      echo "$n"
    done
  fi
}

names | sort -u | while read -r d; do
  { [ -z "$d" ] || [ ! -e "/sys/block/$d" ]; } && continue
  [ "$(cat "/sys/block/$d/queue/rotational" 2>/dev/null)" = "1" ] || continue
  sg=$(basename "$(readlink -f "/sys/block/$d/device/generic" 2>/dev/null)" 2>/dev/null)
  { [ -n "$sg" ] && [ -e "/dev/$sg" ]; } && echo "$d $sg"
done
