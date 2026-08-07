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
3. hd-idle issues SCSI STANDBY after idle timeout
4. smartd doesn't force checks on sleeping disks

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

## 3. hd-idle

```bash
apt-get install -y hd-idle
```

`/etc/default/hd-idle` — `-i 0` default protects rpool SSDs; `-p 3` =
SCSI STANDBY (mandatory for SAS: default `-p 0` doesn't auto-wake);
1800s = 30min idle:

```bash
START_HD_IDLE=true
HD_IDLE_OPTS="-i 0 -s 1 \
  -a /dev/disk/by-id/wwn-0x50000397380a8ac9 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x50000397380a8ac5 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x50000397380a8c49 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x5000039738010b45 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x50000397380a8b19 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x50000397380a89f1 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x5000cca07d178f88 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x50000397380a8c0d -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x5000039798597ca1 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x50000397985951c9 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x5000039798595675 -i 1800 -c scsi -p 3 \
  -a /dev/disk/by-id/wwn-0x500003972852117d -i 1800 -c scsi -p 3 \
  -l /var/log/hd-idle.log"
```

```bash
systemctl daemon-reload && systemctl enable --now hd-idle
```

## 4. smartd — exclude the SAS disks entirely

smartd's `-n standby` power-mode skip is **ATA-only** (same limitation
that forced unRAID to ship a smartctl wrapper). On SCSI/SAS it checks
anyway — `-n standby,999,q` was tried and did nothing. Each forced check
wakes the disk via SG_IO (invisible to hd-idle, which then never re-issues
standby → disk stays awake forever) and fires false
"FailedReadSmartSelfTestLog" alerts.

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
# after 30min real idle, all 12 = STANDBY:
for d in sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp; do
  out=$(smartctl -i -n standby /dev/$d 2>&1)
  echo "$d: $(echo "$out" | grep -qi STANDBY && echo STANDBY || echo ACTIVE)"
done

# wake test — one disk wakes, the rest stay asleep, pool stays ONLINE:
dd if=/dev/disk/by-id/wwn-0x5000cca07d178f88 of=/dev/null bs=1M count=4
zpool status media
```

## The SG_IO blind spot (root cause of "it randomly stops sleeping")

hd-idle decides idle purely from `/proc/diskstats` — real block-layer
I/O. Any tool that queries a disk via SCSI Generic (SG_IO) — `smartctl`
without `-n`, `sg_start`, Proxmox's own disk-health code — physically
spins the disk up **without touching diskstats at all**. hd-idle never
sees it happen, still believes the disk is asleep (it already issued
STOP and saw no diskstats change since), and never issues a second STOP.
The disk just stays spinning, invisibly, until something restarts
hd-idle and forces a fresh read of reality.

**All known SG_IO sources on this host, and their state:**

| Source | Status |
|---|---|
| smartd periodic checks | Fixed — SAS excluded entirely (§4) |
| Controller patrol read | Fixed — disabled (§1) |
| `sas-health-check.sh` | Fixed — every `smartctl` call uses `-n standby`, skips sleeping disks instead of waking them |
| Proxmox web UI → Datacenter → pve → **Disks** tab | **Not fixable** — `PVE::Diskmanage::get_smart_data` (Proxmox core, `API2/Disks.pm`) calls `smartctl -H` with no `-n` flag. Opening that page wakes every SAS disk. Known tradeoff, not a bug to chase. |
| Manual `smartctl`/`sg_start` without `-n standby` | Always pass `-n standby` on SAS disks, or accept the wake |

**Safety net** (`hd-idle-resync.timer`, twice daily 06:00/18:00):
restarts hd-idle unconditionally, so even an SG_IO source not yet
identified self-heals within 12h instead of staying silently broken.

```bash
cat > /etc/systemd/system/hd-idle-resync.service <<'UNIT'
[Unit]
Description=Resync hd-idle idle-tracking state (safety net against SG_IO desync)

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart hd-idle
UNIT
cat > /etc/systemd/system/hd-idle-resync.timer <<'UNIT'
[Unit]
Description=Restart hd-idle twice daily to self-heal any SG_IO-caused desync

[Timer]
OnCalendar=*-*-* 06,18:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload && systemctl enable --now hd-idle-resync.timer
```

## Other troubleshooting

- **`smartctl -n standby` prints nothing / exit 2**: disk is asleep —
  that's the skip working, not an error.
- **A disk never comes back after standby**: some models (HGST) need an
  explicit start — `sg_start --start /dev/sdX`. Only `sdk` here is HGST.

[README.md](README.md#nightly-schedule) has the backup window this
aligns with.
