# R730xd — SAS pool spin-down setup

Runbook to reapply after a full Proxmox reinstall on `pve`. Covers only the
spin-down-specific pieces — ZFS pool import/rebuild is separate, standard
`zpool import`. The 12 SAS disk WWNs below are hardware IDs, stable across
reinstalls (same physical drives).

## 1. Install storcli (patrol read control)

```bash
apt-get install -y unzip
cd /root
curl -fsSL -o storcli_rel.zip "https://docs.broadcom.com/docs-and-downloads/007.2705.0000.0000_storcli_rel.zip"
unzip -q storcli_rel.zip -d storcli_rel
unzip -q storcli_rel/storcli_rel/Unified_storcli_all_os.zip -d storcli_rel/unified
dpkg -i storcli_rel/unified/Unified_storcli_all_os/Ubuntu/storcli_007.2705.0000.0000_all.deb
ln -sf /opt/MegaRAID/storcli/storcli64 /usr/sbin/storcli
rm -rf storcli_rel.zip storcli_rel
storcli /c0 show all | head -5   # sanity check
```

## 2. Disable patrol read

Controller (PERC H730P Mini) runs a weekly patrol read by default — wakes
every disk regardless of spin-down.

```bash
storcli /c0 set patrolread=off
storcli /c0 show patrolread | grep "PR Mode"   # expect: Disable
```

## 3. Eliminate every continuous writer on the pool (the actual root cause)

ZFS commits a txg every `zfs_txg_timeout` seconds (default 5) — but **only
if there is dirty data**. An idle pool with zero writers commits nothing
and its disks can sleep indefinitely at the default setting. So the fix is
NOT raising `zfs_txg_timeout` — that was tried first (3600s) and it
backfired: the parameter is module-global, so rpool (where the etcd VMs
live) started batching ~860MB write bursts every ~23min, spiking etcd 99p
commit latency and firing Telegram alerts all night. Keep the default;
hunt writers instead.

**Known writer on this host (found 2026-08-07): Garage's metadata.** The
Garage LXC (103) writes its LMDB lock + peer_list heartbeat a few MB/hour,
which alone forced an hourly txg → hourly full-pool spin-up, perfectly
30min-sleep/30min-awake cycling against hd-idle's 30min timer. Fix in
place: meta lives on `rpool/garage-meta` (SSD, mp1 of LXC 103), and
`/root/scripts/garage-meta-nightly-copy.sh` (cron 03:01, inside the backup
window) mirrors it back to `media/backups/longhorn-garage/meta/` so all
downstream backup legs (ZFS snapshots, restic→Oracle, weekly Synology)
still cover it unchanged.

To find any new writer later:

```bash
# what changed recently on the pool:
find /media -newermt "2 hours ago" -type f
# txg commit history — otime column shows real commit cadence:
tail -15 /proc/spl/kstat/zfs/media/txgs
# steady state check — write counters must be identical:
grep -E " sd[a-z]+ " /proc/diskstats | awk '{print $3, $10}'; sleep 60; \
grep -E " sd[a-z]+ " /proc/diskstats | awk '{print $3, $10}'
```

## 4. Install and configure hd-idle

```bash
apt-get install -y hd-idle
```

`/etc/default/hd-idle`:

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

`-i 0` default = never touch anything not listed (protects `rpool` SSDs).
`-p 3` = SCSI STANDBY (required for SAS — `-p 0`/default does not
auto-wake SAS disks on access). 1800s = 30min idle before spin-down.

```bash
systemctl daemon-reload
systemctl restart hd-idle
systemctl enable hd-idle
```

## 5. Fix smartd's own spin-down killer (easy to miss — found live 2026-08-07)

Debian's default `/etc/smartd.conf` has `-n standby` with **no skip-count
limit**. Undocumented default: after a handful of skipped checks on a
standby disk, smartd forces one anyway — that forced check hits the disk
mid-spin-up, the self-test-log read fails ("FailedReadSmartSelfTestLog"
warning email/notification), and the forced check itself wakes the disk,
resetting hd-idle's 30min timer. Net effect: disks cycle active/standby
every ~30-60min all night instead of resting for hours, plus a flood of
false-positive SMART error notifications. Confirmed via
`overnight-watch.log` — pattern was invisible in short spot-checks, only
showed up over a multi-hour log.

```bash
sed -i 's/-n standby /-n standby,999,q /' /etc/smartd.conf
systemctl restart smartmontools
```

`,999` = skip up to 999 checks (~20 days at the 30min interval) before
forcing one. `,q` = don't log/alert on a skip. Real disk problems (actual
SMART failures, not power-mode-related) still get caught next time the
disk is genuinely active — this only stops smartd from being the thing
that keeps it awake.

## 6. Verify

```bash
# after ~30min real idle (no backup job, no Jellyfin), all 12 should show STANDBY:
for d in sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp; do
  out=$(smartctl -i -n standby /dev/$d 2>&1)
  echo "$d: $(echo "$out" | grep -qi STANDBY && echo STANDBY || echo "$out" | grep -i 'power mode')"
done

# wake test — read one disk directly, confirm isolated wake + pool stays healthy:
dd if=/dev/disk/by-id/wwn-0x5000cca07d178f88 of=/dev/null bs=1M count=4
zpool status media
```

See [README.md](README.md#nightly-schedule-spin-down-aligned) for the
nightly backup window this is aligned against.
