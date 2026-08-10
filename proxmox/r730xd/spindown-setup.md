# R730xd — SAS pool spin-down setup

Runbook for a fresh Proxmox reinstall on `pve`. Spin-down pieces only —
pool import is standard `zpool import`. WWNs are hardware IDs, stable
across reinstalls.

⚠️ **Not covered here, recreate separately**: `/root/PRIVATE-NOTES.md`
(Synology wake schedule + WoL MAC — deliberately not in git, see
[README.md](README.md#nightly-schedule)) is lost on reinstall. Get the
current values from whoever has DSM access, or from the DSM Power
Schedule UI directly.

Four things must all be true for the disks to sleep:
1. Controller doesn't poll them (patrol read off)
2. Nothing writes to the pool outside the backup window (no txg commits)
3. The spin-down enforcer issues SCSI STANDBY after idle (§3)
4. smartd doesn't force checks on sleeping disks (§4)

## 1. storcli + patrol read off

Patrol read (weekly, controller-level) wakes every disk regardless of OS
settings.

```bash
apt-get install -y unzip
cd /root
# Mirrored at /media/backups/tools/ and explicitly added to the restic and
# Synology legs (both enumerate subdirectories, so a new one is NOT picked up
# automatically - that was checked, not assumed) -
# Broadcom's download URLs do not stay valid for years, and a reinstall is
# exactly when you need this. Use the mirror first, the URL as fallback:
#   dpkg -i /media/backups/tools/storcli_007.2705.0000.0000_all.deb
curl -fsSL -o storcli_rel.zip "https://docs.broadcom.com/docs-and-downloads/007.2705.0000.0000_storcli_rel.zip"
unzip -q storcli_rel.zip -d storcli_rel
unzip -q storcli_rel/storcli_rel/Unified_storcli_all_os.zip -d storcli_rel/unified
dpkg -i storcli_rel/unified/Unified_storcli_all_os/Ubuntu/storcli_007.2705.0000.0000_all.deb
ln -sf /opt/MegaRAID/storcli/storcli64 /usr/sbin/storcli
rm -rf storcli_rel.zip storcli_rel

storcli /c0 set patrolread=off
storcli /c0 show patrolread | grep "PR Mode"   # expect: Disable
```

## 2. Zero writers on the pool

ZFS commits a txg only when there's dirty data — an untouched pool writes
nothing and sleeps indefinitely at default `zfs_txg_timeout=5`. **Do not
raise `zfs_txg_timeout`** — it's module-global; at 3600s rpool batched
~860MB bursts that spiked etcd commit latency. Hunt writers instead.

Known writer: **Garage meta** (LMDB lock + heartbeat, a few MB/hour →
hourly txg → hourly full-pool wake). Fix: meta on SSD, nightly copy back
into the covered backup path:

```bash
pct stop 103
zfs create -o mountpoint=/rpool/garage-meta rpool/garage-meta
# fresh rebuild: restore meta from the nightly copy (all backup legs cover it)
rsync -a /media/backups/longhorn-garage/meta/ /rpool/garage-meta/
sed -i 's#^mp1: .*#mp1: /rpool/garage-meta,mp=/srv/docker/garage/meta#' /etc/pve/lxc/103.conf
pct start 103
pct exec 103 -- docker exec garage /garage bucket list   # sanity: meta intact

cat > /root/scripts/garage-meta-nightly-copy.sh <<'SH'
#!/bin/bash
set -euo pipefail
rsync -a --delete /rpool/garage-meta/ /media/backups/longhorn-garage/meta/
SH
chmod +x /root/scripts/garage-meta-nightly-copy.sh
( crontab -l; echo "1 3 * * * /root/scripts/garage-meta-nightly-copy.sh >> /var/log/garage-meta-copy.log 2>&1" ) | crontab -
```

**Second known waker: Jellyfin's real-time library monitor.** Jellyfin
watches library folders for changes continuously (`LibraryMonitor:
Watching directory /media/Movies`). Over NFS this is a steady trickle of
metadata reads — enough to keep every disk in the vdev awake permanently,
even though `find -newermt` shows no file changes and txg commits carry
zero bytes. Disable per library:

```bash
POD=$(kubectl get pods -n default -o name | grep jellyfin | head -1)
kubectl exec -n default ${POD#pod/} -- sh -c '
for f in /config/root/default/*/options.xml; do
  sed -i "s#<EnableRealtimeMonitor>true<#<EnableRealtimeMonitor>false<#" "$f"
done'
kubectl rollout restart deployment -n default jellyfin
# verify: no "Watching directory" lines in the new pod's log
```

Lives in Jellyfin's own config (PVC), not git — recheck after any
library re-add. Trade-off: new downloads appear at the next scheduled
scan instead of instantly.

Finding a new writer:

```bash
find /media -newermt "2 hours ago" -type f          # recently touched files
tail -15 /proc/spl/kstat/zfs/media/txgs             # commit cadence (otime col)
grep -E " sd[a-z]+ " /proc/diskstats | awk '{print $3, $10}'; sleep 60; \
grep -E " sd[a-z]+ " /proc/diskstats | awk '{print $3, $10}'   # must be identical
```

## 3. Spin-down enforcer (stateless, replaces hd-idle)

hd-idle was used first and **abandoned**: it tracks idle time from
`/proc/diskstats` and remembers "I already spun this disk down" — but
SG_IO queries (Proxmox's Disks UI tab, any `smartctl` without `-n`,
`sg_start`) wake disks *without* touching diskstats, so hd-idle's state
went stale and the disk stayed awake forever until a manual restart.

The replacement is a ~30-line stateless script on a 5-min systemd timer:
each run reads the disk's **real power state** and re-decides from
scratch. Two consecutive runs with zero diskstats change (~10-15 min
idle) → SCSI STANDBY. A disk woken by anything, visible or not, is
re-slept within ~15 min by design — no state to desync, nothing to
restart.

> ⚠️ **The single most important detail on this page.** Every SCSI
> command must target the **generic** device (`/dev/sgN`), never the
> block device (`/dev/sdX`). Issuing `sg_start --pc=3 /dev/sdp` succeeds,
> the drive genuinely stops — and the kernel spins it straight back up
> when the block device is closed (revalidation). Nothing appears in
> `/proc/diskstats` because the whole exchange happens below the block
> layer, which makes it look like a phantom wake-up from nowhere.
> Measured 2026-08-07, same command, all 12 disks:
> `/dev/sdX` → 154-170W (awake within seconds, every time);
> `/dev/sgN` → 131-136W, sustained. Map with
> `basename $(readlink -f /sys/block/sdX/device/generic)`.

```bash
apt-get install -y sg3-utils smartmontools

# Single source of truth for the disk list - used by the enforcer, the
# health check and the manual verify sweep. Never hardcode sdX names.
cat > /root/scripts/sas-disks.sh <<'SH'
#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin, and smartctl/storcli/
# zpool live in /usr/sbin - without this they are silently not found and every
# check reports a false failure.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Single source of truth: which disks are the media pool's SAS members.
# Prints one "sdX sgN" pair per line, derived from the pool itself - so a disk
# replacement, a moved slot or an HBA reshuffle updates every consumer at once
# instead of leaving one of them quietly lying. Rotational check means an SSD
# can never appear here. (lsblk TRAN is empty for these: they sit behind the
# MegaRAID controller, so a transport-type filter finds nothing.)
set -uo pipefail
POOL="${SAS_POOL:-media}"   # override with SAS_POOL=... if the pool is renamed
zpool status "$POOL" 2>/dev/null | grep -oE "wwn-0x[0-9a-f]+" | sort -u | while read -r wwn; do
  d=$(basename "$(readlink -f "/dev/disk/by-id/$wwn" 2>/dev/null)" 2>/dev/null)
  { [ -z "$d" ] || [ ! -e "/sys/block/$d" ]; } && continue
  [ "$(cat "/sys/block/$d/queue/rotational" 2>/dev/null)" = "1" ] || continue
  sg=$(basename "$(readlink -f "/sys/block/$d/device/generic" 2>/dev/null)" 2>/dev/null)
  { [ -n "$sg" ] && [ -e "/dev/$sg" ]; } && echo "$d $sg"
done
SH
chmod +x /root/scripts/sas-disks.sh

cat > /root/scripts/sas-spindown.sh <<'SH'
#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin, and smartctl/storcli/
# zpool live in /usr/sbin - without this they are silently not found and every
# check reports a false failure.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Stateless SAS spin-down enforcer.
#
# CRITICAL: all SCSI commands go to the *generic* device (/dev/sgN), never the
# block device (/dev/sdX). Issuing START STOP UNIT on /dev/sdX makes the kernel
# revalidate the block device on close and immediately spin the disk back up -
# the standby never sticks, and nothing shows in /proc/diskstats because the
# whole exchange happens below the block layer.
#
# The disk list comes from /root/scripts/sas-disks.sh - the one place that
# derives it from the pool itself. Never hardcode names here or anywhere else.
set -uo pipefail
exec 9>/run/sas-spindown.lock
flock -n 9 || exit 0
STATE=/run/sas-spindown.state   # tmpfs - reset on reboot, by design
declare -A prev idle
if [ -f "$STATE" ]; then
  while read -r d io n; do prev[$d]=$io; idle[$d]=$n; done < "$STATE"
fi

if ! mapfile -t DISKS < <(/root/scripts/sas-disks.sh) || [ "${#DISKS[@]}" -eq 0 ]; then
  logger -t sas-spindown "ERROR: sas-disks.sh returned no disks - doing nothing"
  exit 1
fi

: > "$STATE.new"
to_sleep=()
for entry in "${DISKS[@]}"; do
  d=${entry%% *}; sg=${entry##* }
  io=$(awk -v d="$d" '$3==d {print $4"+"$8}' /proc/diskstats)
  [ -z "$io" ] && continue
  # Capture first, then match - never `cmd | grep -q` under `set -o pipefail`:
  # grep exits on the first match, the producer gets SIGPIPE, and the pipeline
  # reports failure even though the match succeeded.
  # Awake only on an explicit ACTIVE; standby, timeout or error = leave alone.
  pm=$(smartctl -i -n standby "/dev/$sg" 2>&1 || true)
  case "$pm" in
    *"Power mode is:"*ACTIVE*) ;;
    *) echo "$d $io 0" >> "$STATE.new"; continue ;;
  esac
  n=0
  if [ "${prev[$d]:-}" = "$io" ]; then
    n=$(( ${idle[$d]:-0} + 1 ))
    if [ "$n" -ge 2 ]; then to_sleep+=("/dev/$sg:$d"); n=0; fi
  fi
  echo "$d $io $n" >> "$STATE.new"
done
mv "$STATE.new" "$STATE"
# Parallel: each sg_start blocks ~9s while the platter stops.
for entry in "${to_sleep[@]}"; do
  ( sg_start --pc=3 "${entry%%:*}" >/dev/null 2>&1 \
    && logger -t sas-spindown "standby issued: ${entry##*:} via ${entry%%:*}" ) &
done
wait
SH
chmod +x /root/scripts/sas-spindown.sh

cat > /etc/systemd/system/sas-spindown.service <<'UNIT'
[Unit]
Description=Stateless SAS spin-down enforcer (media pool)

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
systemctl daemon-reload && systemctl enable --now sas-spindown.timer
```

Notes:
- `-pc=3` (SCSI STANDBY) is mandatory for SAS — disks auto-wake on I/O.
  STOP does not.
- Device names (`sde`..`sdp`) are fine here (unlike ZFS commands): the
  script only reads stats/power state per boot session; a name shuffle
  after reboot still resolves to exactly the 12 SAS disks because the 4
  SSDs are sda-sdd on this controller. If the disk set ever changes,
  update the list.
- Spin-down latency = 2-3 timer ticks (10-15 min of real idle). Change
  cadence via `OnUnitActiveSec`, not the script.

## 4. smartd — exclude the SAS disks entirely

smartd's `-n standby` power-mode skip is **ATA-only** (same limitation
that forced unRAID to ship a smartctl wrapper). On SCSI/SAS it checks
anyway — `-n standby,999,q` was tried and did nothing. Each forced check
wakes the disk via SG_IO and fires false "FailedReadSmartSelfTestLog"
alerts every 30 minutes, all night. The enforcer (§3) re-sleeps such
wakes, but the pointless wake/alert cycle itself is worth removing at
the source.

Fix: smartd monitors only the 4 rpool SSDs, by-id:

```
# /etc/smartd.conf — replace DEVICESCAN entirely with:
DEFAULT -m root -M exec /usr/share/smartmontools/smartd-runner
/dev/disk/by-id/ata-INTEL_SSDSC2KB960G8_BTYF91650CDW960CGN -d sat
/dev/disk/by-id/ata-INTEL_SSDSC2KB960G8_BTYF91650F29960CGN -d sat
/dev/disk/by-id/ata-INTEL_SSDSC2KB960G8_BTYF91650EVS960CGN -d sat
/dev/disk/by-id/ata-INTEL_SSDSC2KB960G8_BTYF91650A5R960CGN -d sat
```

```bash
systemctl restart smartmontools
journalctl -u smartmontools -n 5 | grep Monitoring   # expect: 4 ATA, 0 SCSI
```

SAS health is covered instead by a nightly script (backup window, disks
already awake): SMART health + grown defects + uncorrected error counters
+ zpool READ/WRITE/CKSUM, mails root only on anomalies — same channel
smartd used.

```bash
cat > /root/scripts/sas-health-check.sh <<'SH'
#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin, and smartctl/storcli/
# zpool live in /usr/sbin - without this they are silently not found and every
# check reports a false failure.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Nightly SAS health check - replaces smartd for the 12 media-pool disks
# (smartd's -n standby is ATA-only; on SAS it force-wakes sleeping disks).
# Runs inside the backup window while disks are awake anyway. Alerts root
# (same channel smartd used) only on real anomalies.
set -uo pipefail
ALERT=""
skipped=0
while read -r d sg; do
  out=$(smartctl -n standby -H -l error "/dev/$sg" 2>&1)
  # A sleeping disk returns no health data - that is not a fault. Skip it;
  # it gets checked on a night when the backup window has it awake.
  case "$out" in *STANDBY*) skipped=$((skipped+1)); continue ;; esac
  health=$(echo "$out" | grep -i "SMART Health Status" | awk -F: '{print $2}' | xargs)
  defects=$(smartctl -n standby -a "/dev/$sg" 2>/dev/null | grep -i "grown defect" | grep -oE '[0-9]+$')
  uncorr=$(echo "$out" | awk '/^read:|^write:|^verify:/ {print $NF}' | awk '{s+=$1} END {print s}')
  [ "$health" != "OK" ] && ALERT="$ALERT\n$d: health=$health"
  [ "${defects:-0}" -gt 0 ] && ALERT="$ALERT\n$d: grown defects=$defects"
  [ "${uncorr:-0}" -gt 0 ] && ALERT="$ALERT\n$d: uncorrected errors=$uncorr"
done < <(/root/scripts/sas-disks.sh)
zerr=$(zpool status media | awk '/ONLINE|DEGRADED|FAULTED/ && $3 ~ /[0-9]/ {if ($3+$4+$5 > 0) print $1": "$3"/"$4"/"$5}')
[ -n "$zerr" ] && ALERT="$ALERT\nzpool error counters:\n$zerr"
if [ -n "$ALERT" ]; then
  echo -e "SAS health anomalies on pve:$ALERT" | mail -s "SAS health alert (pve)" root
fi
total=$(/root/scripts/sas-disks.sh | wc -l)
echo "$(date '+%F %T') checked $((total-skipped))/$total disks (${skipped} asleep, skipped), alert='${ALERT:-none}'"
SH
chmod +x /root/scripts/sas-health-check.sh
( crontab -l; echo "20 3 * * * /root/scripts/sas-health-check.sh >> /var/log/sas-health.log 2>&1" ) | crontab -
```

## 5. Verify

⚠️ **Don't poll with `smartctl` while waiting.** Even with `-n standby`
it's an SG_IO round-trip on any disk that is *currently awake*, which
bumps its counters and resets the idle tally — repeated checks keep the
disks awake forever and make it look broken. Watch these two instead,
neither of which touches a disk:

```bash
journalctl -t sas-spindown -f                    # "standby issued: sdX"
ipmitool sensor | grep -i "Pwr Consumption"      # ~126W all-asleep, ~168W all-awake
```

One `smartctl` sweep is fine to confirm the end state, just don't loop it:

```bash
while read -r d sg; do
  out=$(smartctl -i -n standby "/dev/$sg" 2>&1)
  echo "$d: $(echo "$out" | grep -qi STANDBY && echo STANDBY || echo ACTIVE)"
done < <(/root/scripts/sas-disks.sh)

# wake test — one disk wakes, the rest stay asleep, pool stays ONLINE,
# and the enforcer re-sleeps it within ~15 min without intervention:
dd if=/dev/disk/by-id/wwn-0x5000cca07d178f88 of=/dev/null bs=1M count=4
zpool status media
```

## 6. Status reporting (operator convenience)

Two pieces, both **passive — they never touch a disk**, so they can be run
or scheduled freely without disturbing what they measure (polling with
`smartctl` was itself the reason several early measurements looked broken).

`/root/scripts/spindown-report.sh` on a 10-min timer appends one line per
sample to `/var/log/spindown-history.log`; `/root/spindown-summary.sh`
turns that into a phone-readable verdict:

```
── SPINDOWN 09.08 22:55 ──
acum:         ADORMITE (126 W)
ultimele 2h:  11/12 (91%)
ultimele 24h: 118/144 (81%)
de la boot:   1/3 (33%)  [08-09 22:14]
cmd standby (24h): 12
pool: state: ONLINE (ok)
```

```bash
cat > /root/spindown-summary.sh <<'SH'
#!/bin/bash
# Phone-friendly spin-down status. Touches NO disk (safe any time).
# Time windows compare the "YYYY-MM-DD HH:MM" prefix as text - correct because
# the format sorts chronologically, and avoids per-line date(1) calls.
LOG=/var/log/spindown-history.log
now_i=$(ipmitool sensor 2>/dev/null | grep -i "Pwr Consumption" | awk -F'|' '{print $2}' | xargs | cut -d. -f1)
if [ "${now_i:-999}" -lt 140 ]; then state="ADORMITE"; else state="TREZE"; fi
window() {  # $1 = cutoff timestamp "YYYY-MM-DD HH:MM"
  awk -v cut="$1" '
    { ts = substr($0,1,16)
      if (ts >= cut) { n++
        if (match($0,/idrac=[0-9]+/)) { w = substr($0,RSTART+6,RLENGTH-6)+0
          if (w > 0 && w < 140) c++ } } }
    END { if (n>0) printf "%d/%d (%d%%)", c+0, n, (c+0)*100/n; else printf "fara date inca" }' "$LOG" 2>/dev/null
}
echo "── SPINDOWN $(date '+%d.%m %H:%M') ──"
echo "acum:         $state ($now_i W)"
echo "ultimele 2h:  $(window "$(date -d '-2 hours' '+%F %H:%M')")"
echo "ultimele 24h: $(window "$(date -d '-24 hours' '+%F %H:%M')")"
echo "de la boot:   $(window "$(date -d "$(uptime -s)" '+%F %H:%M')")  [$(uptime -s | cut -c6-16)]"
echo "cmd standby (24h): $(journalctl -t sas-spindown --since '24 hours ago' 2>/dev/null | grep -c 'standby issued')"
zs=$(zpool status media 2>/dev/null | grep -E "^ state:" | xargs)
ze=$(zpool status media 2>/dev/null | grep -cE "DEGRADED|FAULTED|OFFLINE")
echo "pool: $zs $([ "$ze" -gt 0 ] && echo '<-- ATENTIE' || echo '(ok)')"
echo "───────────────────────"
echo "126W=dorm  150W+=treze"
SH
chmod +x /root/spindown-summary.sh
```

Read it as: `acum` is the live answer; the windows show what fraction of
samples had the pool asleep. >80% during normal days is healthy. A `pool:`
line other than ONLINE is a real disk problem, unrelated to spin-down.

## 7. Drift detection (nightly)

Several pieces of this setup live outside git by nature - Jellyfin's
realtime-monitor toggle is in its PVC, Garage's mount is in the LXC
config, patrol read is in controller NVRAM. Rather than trusting anyone
to remember to re-check them, the nightly job checks the **outcome**:
did the pool actually sleep? That catches wakers nobody has thought of
yet, and cannot rot the way a list of config checks does. A few cheap
local invariants are verified alongside it.

```bash
cat > /root/scripts/spindown-drift-check.sh <<'SH'
#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin, and smartctl/storcli/
# zpool live in /usr/sbin - without this they are silently not found and every
# check reports a false failure.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Nightly drift detection for the spin-down setup.
#
# Deliberately OUTCOME-based, not config-based: rather than enumerating every
# known waker (Jellyfin realtime monitor, Garage meta location, ...) and
# checking each is still set correctly, it asks the only question that matters
# - did the pool actually sleep? That also catches wakers nobody has thought
# of yet, and it cannot rot the way a list of config checks does.
# Cheap local invariants that need no cluster access are checked too.
set -uo pipefail
LOG=/var/log/spindown-history.log
ALERT=""

cut=$(date -d '-24 hours' '+%F %H:%M')
read -r slept total < <(awk -v cut="$cut" '
  { ts=substr($0,1,16); if (ts>=cut) { n++; if (match($0,/idrac=[0-9]+/)) {
      w=substr($0,RSTART+6,RLENGTH-6)+0; if (w>0 && w<140) c++ } } }
  END { print c+0, n+0 }' "$LOG" 2>/dev/null)
if [ "${total:-0}" -ge 60 ]; then          # need a meaningful sample (~10h)
  pct=$(( slept * 100 / total ))
  [ "$pct" -lt 30 ] && ALERT="$ALERT\nPool asleep only ${pct}% of the last 24h (${slept}/${total} samples).\nSomething is keeping the SAS disks awake - see proxmox/r730xd/spindown-setup.md,\nsection 'Zero writers on the pool'."
fi

pr=$(storcli /c0 show patrolread 2>/dev/null | grep -c "PR Mode.*Disable")
[ "$pr" -eq 0 ] && ALERT="$ALERT\nController patrol read is no longer disabled."
grep -q "^mp1: /rpool/garage-meta" /etc/pve/lxc/103.conf 2>/dev/null \
  || ALERT="$ALERT\nGarage meta is no longer bind-mounted from rpool (LXC 103 mp1)."
# grep -c, not grep -q: -q exits on first match, journalctl gets SIGPIPE and
# returns 141, and under `set -o pipefail` that reads as a failed check - a
# false alert even though the match was found.
smartd_sas=$(journalctl -u smartmontools -b --no-pager 2>/dev/null | grep -c "0 SCSI/SAS" || true)
[ "${smartd_sas:-0}" -eq 0 ] \
  && ALERT="$ALERT\nsmartd is monitoring SAS disks again (should be SSD-only)."
systemctl is-active --quiet sas-spindown.timer \
  || ALERT="$ALERT\nsas-spindown.timer is not active."

if [ -n "$ALERT" ]; then
  echo -e "Spin-down drift detected on pve:$ALERT" | mail -s "Spin-down drift (pve)" root
  echo "$(date '+%F %T') DRIFT:$ALERT"
else
  echo "$(date '+%F %T') ok (24h asleep: ${slept:-?}/${total:-?})"
fi
SH
chmod +x /root/scripts/spindown-drift-check.sh
( crontab -l; echo "25 3 * * * /root/scripts/spindown-drift-check.sh >> /var/log/spindown-drift.log 2>&1" ) | crontab -
```

## Changing the disk set

Nothing here needs editing when disks change — the enforcer, the health
check and the verify sweep all read `sas-disks.sh`, which derives the
list from the pool at every run.

| What you do | What happens |
|---|---|
| Replace a failed disk | New wwn appears in `zpool status` → picked up on the next 5-min tick. No action. |
| Add a vdev (e.g. +2 disks) | Same — new members are simply part of the list. No action. |
| Pull a disk physically | Its `by-id` symlink stops resolving → skipped silently, the rest keep working. |
| Slot move / HBA reshuffle | sdX names change, wwn IDs do not → list still correct. |
| Rename the pool | The one thing to adjust: `SAS_POOL=` in `sas-disks.sh` (defaults to `media`). |
| Add an SSD to the pool | Refused by the rotational check — spin-down only ever targets spinning disks. |

Verified by test, not assumption: a bogus wwn is ignored without error,
and an rpool SSD's wwn is rejected (`rotational=0`).

## Two traps these scripts are written around

Both bit on the first night in production — everything worked by hand and
failed from cron.

**User crontabs get `PATH=/usr/bin:/bin`.** `/etc/crontab` has a fuller
PATH, but `crontab -e` entries do not inherit it. `smartctl`, `storcli` and
`zpool` all live in `/usr/sbin`, so every check silently found nothing and
reported a failure. Each script now sets PATH explicitly rather than
trusting its caller.

**Never `cmd | grep -q` under `set -o pipefail`.** `grep -q` exits at the
first match, the producer gets SIGPIPE and returns 141, and the pipeline
reports failure *even though the match succeeded*. This produced a nightly
"smartd is monitoring SAS disks again" alert while smartd was correctly
configured. Capture the output first, then match it with `case`.

## Known wake sources (all handled or accepted)

Any SG_IO query (`smartctl` without `-n`, `sg_start`, Proxmox's own
disk-health code) physically spins a disk up without touching
`/proc/diskstats`. This is what made hd-idle unusable here (stale state,
disk stayed awake forever). The stateless enforcer makes this class of
problem self-healing — worst case a disk runs ~15 min longer.

| Source | Status |
|---|---|
| smartd periodic checks | Removed at source — SAS excluded (§4) |
| Controller patrol read | Removed at source — disabled (§1) |
| `sas-health-check.sh` | Safe — every `smartctl` call uses `-n standby` |
| Proxmox web UI → Datacenter → pve → **Disks** tab | Wakes every SAS disk (`PVE::Diskmanage::get_smart_data`, no `-n` flag, Proxmox core — not fixable). Enforcer re-sleeps them within ~15 min. |
| Manual `smartctl`/`sg_start` without `-n standby` | Same — re-slept within ~15 min |

## Other troubleshooting

- **`smartctl -n standby` prints nothing / exit 2**: disk is asleep —
  that's the skip working, not an error.
- **A disk never comes back after standby**: some models (HGST) need an
  explicit start — `sg_start --start /dev/sgN`. Only `sdk` here is HGST.

[README.md](README.md#nightly-schedule) has the backup window this
aligns with.
