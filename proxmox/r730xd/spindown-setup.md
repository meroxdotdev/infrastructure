# R730xd — SAS pool spin-down

Parks the 12 SAS disks of the `media` pool when nothing is using it. Worth
~45W (174W → 132W), which is the entire reason this exists.

[`install-spindown.sh`](install-spindown.sh) is the source of truth — it writes
every script and unit. This page explains only what the installer cannot: why
the design is what it is, what breaks it, and how to tell it is working.

```bash
./install-spindown.sh --check    # report state, change nothing
./install-spindown.sh            # install or repair, idempotent
```

⚠️ **Not covered here, recreate separately**: `/root/PRIVATE-NOTES.md`
(Synology wake schedule + WoL MAC — deliberately not in git, see
[README.md](README.md#nightly-schedule)) is lost on reinstall.

---

## The one constraint that shapes everything

All 16 drives sit on **one PERC H730P**, behind a single 24-slot expander
backplane (`BP13G+EXP`): slots 0-3 are the `rpool` SSDs, 4-15 the `media` SAS
disks. There is no way to split them — the backplane has one uplink.

So waking a SAS disk stalls the SSDs. The wake answers sense `2/04/01`
("becoming ready"), `megaraid_sas` turns that into a **blocking** AEN poll
(`megasas_get_pd_list`), and everything else on the controller queues behind
it — including the SSDs carrying the k8s control-plane VM. `zil_commit`
stalls, so etcd's fsync stalls with it.

Two things have changed since that was first written, and both cut the same
way. `rpool` is a 2-disk mirror since 2026-08-27, not a 4-disk RAID10
([rpool-shrink.md](rpool-shrink.md)) — half the spindles absorbing the stall.
And the cluster has been single-node since 2026-08-17, so there is no quorum
to lose: etcd gets slow, it no longer flaps.

Measured 2026-08-16, with the old per-disk enforcer: 24 parks in one hour of
streaming, 346 etcd fsyncs over 1s, 6-11 raft leader elections/day, one 122s
hung-task trace. After the rewrite: 30 fsyncs over 1s (all in the nightly
backup hour, the one wake that has to happen) and zero elections.

**Therefore: park on pool state, never per disk.** `media` is 2× RAIDZ2-6, so
one vdev can idle past any per-disk threshold while its sibling serves a read
stream. Parking those six mid-playback is exactly the failure above. The pool
is the unit of use; if it is quiet, every disk in it is quiet.

⚠️ **The pool gate has one blind spot, and it is handled explicitly.** The idle
counter reads `objset-*` kstats, which count I/O *per dataset*. A scrub or
resilver traverses the pool below the DMU and moves no objset counter at all,
so the gate reads a busy pool as idle. Measured 2026-08-17: `pool_idle` climbed
14 → 15 → 16 straight through a running scrub with all 12 disks awake, and the
enforcer parked every one of them mid-scan. The enforcer now checks
`zpool status` for `scrub in progress` / `resilver in progress` and holds the
counter at zero while either runs. Resilver is the more important half —
parking disks during a rebuild extends the window with no redundancy to spare.
`paused` deliberately does not match: a paused scrub reads nothing.

`EtcdSlowFsyncBurst` in
[kube-prometheus-stack](../../kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml)
alerts if this regresses. The bundled etcd rules do not — they need 10 minutes
sustained, and this failure is sharp spikes that recover in 1-4.

## Two traps

**SCSI commands go to `/dev/sgN`, never `/dev/sdX`.** On the block device the
drive genuinely stops, then the kernel revalidates on close and spins it
straight back up — invisible in `/proc/diskstats`, because it happens below the
block layer. Measured 2026-08-07, same command, all 12 disks: `/dev/sdX` →
154-170W (awake within seconds, every time); `/dev/sgN` → 131-136W, sustained.
Map with `basename $(readlink -f /sys/block/sdX/device/generic)`.

**Never `cmd | grep -q` under `set -o pipefail`.** grep exits on the first
match, the producer takes SIGPIPE and returns 141, and the pipeline reports
failure even though the match succeeded. Capture first, then match.

## Site-specific: writers on the pool

The only part no installer can do. ZFS commits a txg only when there is dirty
data, so an untouched pool sleeps indefinitely at the default
`zfs_txg_timeout=5`. **Do not raise `zfs_txg_timeout`** — it is module-global;
at 3600s rpool batched ~860MB bursts that spiked etcd commit latency. Hunt the
writers instead.

| Writer | Fix | Where it lives |
|---|---|---|
| **Garage meta** — LMDB lock + heartbeat, a few MB/hour → hourly full-pool wake | meta on `rpool/garage-meta`, nightly copy back into the backup path (cron 03:01) | `/etc/pve/lxc/103.conf` mp1 |
| **Jellyfin real-time library monitor** — steady metadata reads over NFS, keeps every disk awake, while `find -newermt` shows nothing | `EnableRealtimeMonitor=false` per library | Jellyfin PVC, **not git** — recheck after any library re-add |
| **qBittorrent seeding** — reads `media/library` at 5-11 MB/min while peers are active | seeding limits so torrents stop (FileList: ratio 1 **or** 48h — set 7 days, safely above) | qBittorrent config |

Seeding is legitimate use: while it runs, the disks stay up and that is
correct. It is bounded by how much you seed, not by a bug.

Finding a new one:

```bash
# which dataset is being read, over 45s
snap(){ for f in /proc/spl/kstat/zfs/media/objset-*; do
  awk '/dataset_name/{n=$3} /^nread/{print n, $3}' "$f"; done; }
snap > /tmp/a; sleep 45; snap > /tmp/b
join /tmp/a /tmp/b | awk '{d=$3-$2; if(d>0) printf "%-42s %9.1f KB\n", $1, d/1024}' | sort -k2 -rn

# then which pod, if it comes in over NFS
ss -tn state established '( sport = :2049 )'      # client IPs
```

## Verify

```bash
grep -v idrac /var/log/spindown-history.log | tail -5
#   2026-08-17 00:01 asleep=12/12 pool_idle=3 watts=141

journalctl -t sas-spindown --since today | grep parked
systemctl list-timers sas-spindown.timer
```

Healthy: `pool_idle` climbs while the pool is quiet, everything parks at 2,
watts drop ~45W. Nothing should park while something is reading — if it does,
the pool gate is broken.

`spindown-drift-check.sh` (nightly 03:25) mails when the parked percentage
drops below 60% of this host's own 7-day baseline, and catches patrol read or
smartd creeping back on. It cannot see the opposite failure — parking *during*
activity — so that one needs the etcd alert above.

## Known wakers

| Source | Status |
|---|---|
| smartd periodic checks | Removed at source — SAS excluded |
| Controller patrol read | Removed at source — `storcli /c0 set patrolread=off` |
| `sas-health-check.sh` | Safe — every `smartctl` uses `-n standby` |
| **Monthly ZFS scrub** | Moved into the window — see below. Default was 00:00 on the 1st, hours of full-pool read entirely outside it. |
| Proxmox web UI → Datacenter → pve → **Disks** tab | Wakes every SAS disk (`PVE::Diskmanage::get_smart_data`, no `-n`, not fixable). Re-slept within ~15 min. |
| Manual `smartctl`/`sg_start` without `-n standby` | Same |
| **`zfs get -r <prop> media`** | Walks every dataset *and snapshot*; woke the pool from 12/12 asleep while measuring on 2026-08-16. Use `-s local` or name datasets explicitly. |
| The enforcer itself, parking mid-stream | Fixed 2026-08-16 — pool-level rule. Was the top waker: 24 parks in one hour of playback. |

### The monthly scrub

Not written by the installer — it is a Debian/Proxmox unit, so it lives here.
`zfs-scrub-monthly@media.timer` defaults to `OnCalendar=monthly` with
`AccuracySec=1d`, i.e. 00:00 on the 1st at an unpinned time: a multi-hour
full-pool read that is a second complete wake of all 12 disks, on top of the
nightly window. Confirmed in `zpool history media` —
`2026-08-01.00:00:45 zpool scrub media`.

```bash
mkdir -p /etc/systemd/system/zfs-scrub-monthly@media.timer.d
cat > /etc/systemd/system/zfs-scrub-monthly@media.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-01 03:40:00
AccuracySec=1h
Persistent=false
EOF
systemctl daemon-reload
```

03:40 starts the scrub as the backup window closes, so it extends one awake
block instead of creating another.

⚠️ **`Persistent=false` is load-bearing, and it is not a default.** systemd's
own default for `Persistent=` is `false`; the `true` comes from the base
template unit `/etc/systemd/system/zfs-scrub-monthly@.timer`, which sets it
explicitly. The drop-in inherits that, so the line above is the only thing
clearing it — verify with `systemctl show zfs-scrub-monthly@media.timer -p
Persistent`, never by reading `override.conf` alone.

With it left on, any `daemon-reload` or boot after the calendar point has
passed counts as a missed run and starts a full-pool scrub *immediately*,
mid-day and outside the window. That is what happened on 2026-08-17 at 13:23
and again at 14:36. Recover with `zpool scrub -p media`; the paused state
persists, and the next scheduled run resumes from where it stopped rather than
restarting.

**Audited 2026-08-28: the line was missing on the host** — the drop-in carried
only `OnCalendar` and `AccuracySec`, so `Persistent=yes` was still in effect
and the failure mode documented above was still armed. Added and verified.
A paused scrub left over from the 2026-08-17 incident had also been sitting at
`0B / 1.78T scanned` for eleven days, waiting for the next timer fire to resume
it.

#### What a scrub actually costs — measured 2026-08-28

The eleven-day-old paused scrub was resumed by hand at 09:40 and ran to
completion: **1.78T, `0B repaired`, 0 errors on all 12 disks, 30 minutes of
real work.** Not the hours the "multi-hour full-pool read" above assumes.

The cost is **not uniform across those 30 minutes**, which is the part worth
knowing. A scrub has two phases and only the first one hurts:

| Phase | What it does | etcd `wal_fsync` p99 | `backend_commit` p99 |
|---|---|---|---|
| idle baseline | — | 10.8 ms | 46.9 ms |
| **metadata scan**, ~1 min | random metadata reads, `scanned` climbs at ~8 G/s | **473 ms** | **636 ms** |
| sequential issue, ~29 min | streaming reads, `issued` at 1.2-1.9 G/s | 15.1 ms → 4.0 ms | 8.0 ms → 5.7 ms |

etcd recovered to **below** its pre-scrub baseline while the scrub was still
running. Zero leader elections, zero fsyncs over 1s, no pod restarts. The only
casualty was one `kube-state-metrics` liveness probe (503) during the metadata
minute; it recovered on its own.

So the earlier framing — that scrub contention on `rpool` is a risk spread
over the whole run — is wrong. **The expensive part is the first minute.** The
03:40 window is still the right place for it, but because of the metadata
scan, not because of sustained bandwidth. It also means a scrub that has
already been running for a few minutes is past its dangerous part; pausing it
then buys nothing and just leaves another zombie.

Power: 112 W idle → 182 W for the duration → ~35 Wh total. Not a
consideration.

⚠️ **The enforcer log goes silent for the whole scrub.** The `scrub in
progress` gate does `exit 0` *before* the line is appended to
`spindown-history.log`, so there is a gap, not a run of awake readings — and
the last line before the gap is a pre-scrub reading that still says
`asleep=12/12`. Do not read it as "the disks stayed parked", and do not build
a wait-loop on it: check the disks directly with `smartctl -n standby` on the
`/dev/sg*` nodes. After completion the counter restarts from zero, so parking
takes two more quiet ticks — measured 10:10 done → 10:16:56 all 12 parked.

There is also a **second, latent trigger**: `/etc/cron.d/zfsutils-linux` runs
`/usr/lib/zfs-linux/scrub` on the second Sunday of the month unless the pool
says otherwise. It was never observed firing, but nothing was stopping it:

```bash
zfs set org.debian:periodic-scrub=disable media
zfs set org.debian:periodic-scrub=disable rpool
```

## Troubleshooting

- **`smartctl -n standby` prints nothing / exit 2**: disk is asleep — that is
  the skip working, not an error.
- **A disk never comes back after standby**: some models (HGST) need an
  explicit `sg_start --start /dev/sgN`. Only `sdk` here is HGST.
- **Nothing ever parks**: something is reading the pool continuously. Find it
  with the snippet above; the gate is doing its job.

[README.md](README.md#nightly-schedule) has the backup window this aligns with.
