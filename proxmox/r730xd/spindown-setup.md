# R730xd — SAS pool spin-down setup

Runbook for a fresh Proxmox reinstall on `pve`. Spin-down pieces only —
pool import is standard `zpool import`. WWNs are hardware IDs, stable
across reinstalls.

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

## 4. smartd

Debian default `-n standby` still force-checks sleeping disks after a few
skips → wakes them mid-transition, resets hd-idle's timer, and fires
false "FailedReadSmartSelfTestLog" alerts. Only visible over multi-hour
logs, never in spot checks.

```bash
sed -i 's/-n standby /-n standby,999,q /' /etc/smartd.conf
systemctl restart smartmontools
```

`,999` = skip limit (~20 days), `,q` = no skip-spam. Real SMART failures
still surface whenever the disk is genuinely active.

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

## Troubleshooting

- **Disks ACTIVE long past the 30min mark, hd-idle log silent**: hd-idle
  tracks state via `/proc/diskstats`, but SG_IO wakes (smartd, manual
  `sg_start`, `smartctl` without `-n`) are invisible there — hd-idle may
  still believe the disk is down and never re-issue standby. Fix:
  `systemctl restart hd-idle` (clean state, spins down 30min later).
- **`smartctl -n standby` prints nothing / exit 2**: disk is asleep —
  that's the skip working, not an error.
- **A disk never comes back after standby**: some models (HGST) need an
  explicit start — `sg_start --start /dev/sdX`. Only `sdk` here is HGST.

[README.md](README.md#nightly-schedule) has the backup window this
aligns with.
