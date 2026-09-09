#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Is there a recent vzdump image of VM 1000?
#
# VM 1000 is the only guest in the estate that is not rebuilt from git, and its
# weekly image was the one backup leg with nothing watching it. The job is
# configured, enabled and scheduled — none of which means it ran. On 2026-09-09
# /media/backups/dump was empty and the newest image of anything on the Synology
# was from 2026-08-23, of two VMs that have since been deleted. Nothing had
# noticed, because nothing was looking.
#
# Eight days, not seven: the job runs Saturday 22:00 and this runs nightly, so a
# seven-day window would go red for a few hours every Saturday evening before
# that night's image lands. Eight gives it one full cycle plus slack, and still
# catches a job that has genuinely stopped by the following Sunday.
#
# Reporting belongs to nightly-checks.sh, which runs this alongside the other
# checks and pings once. This only prints and sets an exit code.
set -uo pipefail

DUMP_DIR="/media/backups/dump"
VMID=1000
MAX_AGE_DAYS=8

if [ ! -d "$DUMP_DIR" ]; then
  echo "$(date '+%F %T') MISSING: $DUMP_DIR does not exist"
  exit 1
fi

# -printf rather than ls: filenames carry the date but the file's own mtime is
# what vzdump actually wrote, and a copied-in file would lie about the former.
newest=$(find "$DUMP_DIR" -maxdepth 1 -name "vzdump-qemu-${VMID}-*.vma.zst" \
         -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)

if [ -z "$newest" ]; then
  echo "$(date '+%F %T') MISSING: no vzdump image of VM $VMID in $DUMP_DIR"
  exit 1
fi

ts=${newest%% *}
path=${newest#* }
age_days=$(( ( $(date +%s) - ${ts%.*} ) / 86400 ))
size=$(du -h "$path" 2>/dev/null | cut -f1)

if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
  echo "$(date '+%F %T') STALE: newest image of VM $VMID is ${age_days}d old ($size, $(basename "$path"))"
  exit 1
fi

echo "$(date '+%F %T') ok (VM $VMID image ${age_days}d old, $size)"
