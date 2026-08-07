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

```bash
apt-get install -y sg3-utils smartmontools

cat > /root/scripts/sas-spindown.sh <<'SH'
#!/bin/bash
set -uo pipefail
exec 9>/run/sas-spindown.lock
flock -n 9 || exit 0
STATE=/run/sas-spindown.state   # tmpfs - reset on reboot, by design
declare -A prev idle
if [ -f "$STATE" ]; then
  while read -r d io n; do prev[$d]=$io; idle[$d]=$n; done < "$STATE"
fi
: > "$STATE.new"
for d in sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp; do
  io=$(awk -v d="$d" '$3==d {print $4"+"$8}' /proc/diskstats)
  [ -z "$io" ] && continue
  if smartctl -i -n standby "/dev/$d" 2>&1 | grep -qi "STANDBY"; then
    echo "$d $io 0" >> "$STATE.new"; continue
  fi
  n=0
  if [ "${prev[$d]:-}" = "$io" ]; then
    n=$(( ${idle[$d]:-0} + 1 ))
    if [ "$n" -ge 2 ]; then
      sg_start --pc=3 "/dev/$d" && logger -t sas-spindown "standby issued: $d"
      n=0
    fi
  fi
  echo "$d $io $n" >> "$STATE.new"
done
mv "$STATE.new" "$STATE"
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
set -uo pipefail
ALERT=""
for d in sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp; do
  out=$(smartctl -n standby -H -l error /dev/$d 2>&1)
  health=$(echo "$out" | grep -i "SMART Health Status" | awk -F: '{print $2}' | xargs)
  defects=$(smartctl -n standby -a /dev/$d 2>/dev/null | grep -i "grown defect" | grep -oE '[0-9]+$')
  uncorr=$(echo "$out" | awk '/^read:|^write:|^verify:/ {print $NF}' | awk '{s+=$1} END {print s}')
  [ "$health" != "OK" ] && ALERT="$ALERT\n$d: health=$health"
  [ "${defects:-0}" -gt 0 ] && ALERT="$ALERT\n$d: grown defects=$defects"
  [ "${uncorr:-0}" -gt 0 ] && ALERT="$ALERT\n$d: uncorrected errors=$uncorr"
done
zerr=$(zpool status media | awk '/ONLINE|DEGRADED|FAULTED/ && $3 ~ /[0-9]/ {if ($3+$4+$5 > 0) print $1": "$3"/"$4"/"$5}')
[ -n "$zerr" ] && ALERT="$ALERT\nzpool error counters:\n$zerr"
if [ -n "$ALERT" ]; then
  echo -e "SAS health anomalies on pve:$ALERT" | mail -s "SAS health alert (pve)" root
fi
echo "$(date '+%F %T') checked 12 disks, alert='${ALERT:-none}'"
SH
chmod +x /root/scripts/sas-health-check.sh
( crontab -l; echo "20 3 * * * /root/scripts/sas-health-check.sh >> /var/log/sas-health.log 2>&1" ) | crontab -
```

## 5. Verify

```bash
# after 10-15 min real idle (2-3 enforcer ticks), all 12 = STANDBY:
for d in sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp; do
  out=$(smartctl -i -n standby /dev/$d 2>&1)
  echo "$d: $(echo "$out" | grep -qi STANDBY && echo STANDBY || echo ACTIVE)"
done
journalctl -t sas-spindown -n 20      # "standby issued" events

# wake test — one disk wakes, the rest stay asleep, pool stays ONLINE,
# and the enforcer re-sleeps it within ~15 min without intervention:
dd if=/dev/disk/by-id/wwn-0x5000cca07d178f88 of=/dev/null bs=1M count=4
zpool status media
```

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
  explicit start — `sg_start --start /dev/sdX`. Only `sdk` here is HGST.

[README.md](README.md#nightly-schedule) has the backup window this
aligns with.
