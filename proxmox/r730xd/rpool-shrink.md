# rpool: 4× SSD RAID10 → 2× SSD mirror

Frees two of the four 960GB Intel SSDs for reuse in the OptiPlex 3050s,
without reinstalling the host.

Related: [REINSTALL.md](REINSTALL.md) · [spindown-setup.md](spindown-setup.md)
(why rpool latency matters here) · [README.md](README.md#storage-layout)

**Done 2026-08-27.** `mirror-1` evacuated online — 255 G copied in 17 minutes
at ~290 MB/s, no errors, no VM interruption, cluster stayed `Ready` throughout.
The pool went from 1.73T/RAID10 to 888G/mirror, 509 G allocated, 57% full,
351 G free. Mapping cost: **5.16 MB of RAM**. The two SSDs were hot-pulled
from slots 2 and 3 with the host running — no shutdown was needed, the
backplane handled it and `zpool status` did not flinch. What follows is the
procedure as executed; it is reusable, but the pool is now a single mirror and
there is nothing left to remove.

**Verdict: possible, online, and reversible only up to the point of no
return.** `rpool` is RAID10 — two mirror vdevs — and ZFS can evacuate one
top-level mirror onto the other with `zpool remove`. It is not a detach: the
pair leaves as a unit, the pool shrinks by half, and the data is copied, not
just re-mirrored.

⚠️ **Not a detach, and not per disk.** Pulling one disk out of each mirror
leaves two degraded mirrors — no redundancy, and no space freed. Both disks
of *one* mirror go, together, after the evacuation finishes.

## What it costs, permanently

| Cost | Detail |
|---|---|
| **Half the IOPS** | Two mirror vdevs stripe; one does not. rpool carries the Talos VM disk (etcd), the Nextcloud zvols, Garage meta and every Longhorn replica |
| **Indirect mapping forever** | Every block that lived on the removed vdev keeps a permanent redirect in the pool, held in RAM. It never goes away, not even if disks are added back |
| **One vdev of redundancy** | Still one whole disk of fault tolerance, but a second failure in the surviving mirror is now the whole pool |
| **No undo after completion** | `zpool remove -s` cancels a removal *in progress*. Once it completes, the only way back is a rebuild from [REINSTALL.md](REINSTALL.md) |

The IOPS line is the one with history. All 16 drives sit on one H730P, and
rpool latency spikes are what surfaced as etcd fsync stalls in August — see
[spindown-setup.md](spindown-setup.md#the-one-constraint-that-shapes-everything).
Halving rpool's spindles moves in the same direction. `EtcdSlowFsyncBurst`
is the alert to watch afterwards.

## 1. Pre-flight

```bash
./rpool-shrink-preflight.sh      # read-only: gates, capacity math, slot map
```

Every gate must read `GO`. What it checks, and why each one blocks:

| Gate | Why |
|---|---|
| all vdevs are mirrors | a raidz/draid vdev anywhere in the pool blocks removal of any vdev |
| exactly 2 mirrors | one is nothing to shrink; three changes which one to pick |
| `feature@device_removal` | `enabled` or `active`; without it there is no removal at all |
| uniform ashift | removal refuses to remap onto a vdev with a larger ashift |
| no scrub/resilver/removal | ZFS refuses to start a second traversal |
| no pool checkpoint | a checkpoint pins the topology and blocks removal |
| capacity after removal < 80% | everything allocated pool-wide must land on the surviving mirror, with room to write |

The capacity gate is the one likely to bite. Nextcloud alone commits 300 G of
thin zvols ([nextcloud/README.md](nextcloud/README.md#2-storage)); the script
prints committed volsize against the post-shrink pool so overcommit is visible
before, not after.

Not enough room → free space first (prune old vzdumps, drop stale
Longhorn replicas, move what belongs on the SAS pool). Do not start a removal
that will run the pool to 90%.

Measured 2026-08-27: 510 GB allocated pool-wide, 255 GB of it on each mirror.
After the shrink that is **57% of an 888 GB mirror** — comfortable. The one
`WARN` is thin-provisioning: 901 GB of zvol volsize committed against 888 GB
of pool. Actual use is 320 GB, so it only bites if VM 800 (400 G), VM 100
(128 G) and the Nextcloud data disk (200 G) all fill up at once. Accepted, not
fixed — the same ceiling logic as
[nextcloud/README.md](nextcloud/README.md#2-storage), one pool smaller.

## 2. Backups before touching anything

Evacuation is hours of sustained read/write on the disks holding every
running VM. Take the safety net first:

```bash
/root/scripts/etcd-snapshot.sh                         # cluster state
vzdump 1000 105 101 --storage sas-backups --mode snapshot   # VMs, onto the SAS pool
zfs snapshot -r rpool@pre-shrink                       # cheap, instant, local
```

`rpool@pre-shrink` is not a backup — it lives on the pool being modified. It
is there for "the removal went fine, the VM did not".

## 3. Remove the mirror

Pick the mirror the pre-flight mapped to the two slots you intend to pull.
Either mirror works; prefer the one whose SSDs show the *higher* wear, and
keep the healthier pair in the server.

```bash
zpool remove rpool mirror-1        # returns immediately, work runs in background
                                   # 255 GB to evacuate, SSD to SSD
watch -n 30 'zpool status rpool'   # "removal in progress", with a copy rate and ETA
```

Run it in a quiet window — not 02:40–03:25, which is the whole nightly backup
chain ([README.md](README.md#nightly-schedule)).

While it runs:

- the pool stays online and writable; VMs keep running
- rpool I/O is slower than usual — expect the odd etcd fsync spike
- the SAS pool is untouched, so nothing wakes the spun-down disks
- `zpool remove -s rpool` aborts and rolls back, at any point before it finishes

Done when `zpool status` reports `removal ... completed` and `zpool list` shows
the pool at half its former size.

## 4. Bootloader, before the disks leave

All four SSDs carry an ESP. Two of them are about to go.

```bash
proxmox-boot-tool status      # confirm both surviving disks are listed
proxmox-boot-tool refresh     # sync current kernels onto every registered ESP
```

If a surviving disk is missing from `status`, initialize it before pulling
anything: `proxmox-boot-tool format /dev/sdX2 && proxmox-boot-tool init /dev/sdX2`.

## 5. Pull them

Enclosure 32, slots 0-3 on the `BP13G+EXP` backplane are the rpool SSDs, and
slot order is left to right across the front: **slot 0 is the leftmost bay**,
slot 3 the fourth. Slots 4-15 are the `media` SAS disks.

Measured 2026-08-27:

| Slot | Bay | Device | Serial | Mirror | Hours | Host writes |
|---|---|---|---|---|---|---|
| 32:0 | 1st from left | `sda` | `BTYF91650CDW960CGN` | mirror-0 | 9035 | 10.6 TB |
| 32:1 | 2nd | `sdb` | `BTYF91650F29960CGN` | mirror-0 | 9036 | 10.9 TB |
| 32:2 | 3rd | `sdc` | `BTYF91650EVS960CGN` | **mirror-1** | 13023 | 17.0 TB |
| 32:3 | 4th | `sdd` | `BTYF91650A5R960CGN` | **mirror-1** | 8931 | 9.9 TB |

Wear indicator reads 100 (0% used) on all four — endurance is not the tiebreak.
`mirror-1` is the one to remove: it holds the oldest, most-written disk, and
leaving `mirror-0` keeps a matched pair (same hours, same writes within 3%) in
the server. It also empties the two rightmost SSD bays instead of punching a
hole in the middle.

**Never pull on the device letter.** `sdX` is assignment order, not position,
and it can change across a reboot. Confirm by serial and by blinking LED:

```bash
sg_ses --dev-slot-num=2 --set=ident /dev/sg16     # blink, confirm by eye
sg_ses --dev-slot-num=3 --set=ident /dev/sg16
sg_ses -p 2 /dev/sg16 | grep -c 'Ident=1'         # read back: expect 2
sg_ses --dev-slot-num=2 --clear=ident /dev/sg16
sg_ses --dev-slot-num=3 --clear=ident /dev/sg16
```

⚠️ **`storcli /c0/eX/sY start locate` does not work on this host** — it
returns `Start Drive Locate Failed` with an empty detail table. The drives are
in JBOD, so the controller does not own their enclosure services. Drive the
LED from the backplane instead: `/dev/sg16` is the SES device
(`DP BP13G+EXP`, find it with `sg_ses --page=0` across `/dev/sg*`), and its
element index equals the device slot number — the same numbering storcli
reports as `32:N`, confirmed against the Additional Element Status page.

Second, independent check before pulling anything: iDRAC → Storage →
Physical Disks lists slot and serial side by side. The serial in the table
above, the blinking carrier and the iDRAC row must all agree.

Pull the two identified disks. **Hot-pull is fine** — done exactly that on
2026-08-27 with every VM running: the vdev was already gone from the pool and
its members marked `(non-allocating)`, so the disks were dead weight by then.
A clean shutdown is the more cautious option and costs a reboot.

⚠️ The ident LED is not visually distinct from the activity LED on these Dell
carriers — all four SSDs appear to blink. To identify a specific disk beyond
doubt, drive I/O at it and watch which carrier goes busy:

```bash
for i in $(seq 1 12); do timeout 15 dd if=/dev/sdc of=/dev/null bs=1M \
  iflag=direct status=none; sleep 10; done
```

15 seconds of heavy activity, 10 quiet, repeating — a rhythm background I/O
does not produce.

```bash
zpool status rpool            # ONLINE, one mirror, no missing devices
proxmox-boot-tool clean       # drops the two ESP UUIDs that no longer exist
proxmox-boot-tool status      # two entries left, both current
```

## 6. Afterwards

- Watch `EtcdSlowFsyncBurst` and Longhorn latency for a few days. This is the
  regression to expect, and it is the reason to keep the pre-shrink numbers.
- Power draw was 111-128 W before, 131 W in the first quiet reading after —
  but that was minutes after a 17-minute evacuation, with load average still
  above 5. Two fewer SATA SSDs is worth ~4-6 W; re-measure in a genuinely idle
  window before recording any number.
- Update the hardware facts that are now wrong: [REINSTALL.md](REINSTALL.md)
  (`rpool`, ZFS RAID10 across the 4× 960GB Intel SSDs),
  [README.md](README.md#storage-layout), and the root
  [README.md](../../README.md) inventory.
- `zfs destroy -r rpool@pre-shrink` once the host has been stable for a week.

## 7. Into the OptiPlex

- **Fit:** these are 2.5" 7mm SATA. An OptiPlex 3050 SFF/MT takes them
  directly; the Micro has one 2.5" bay, so one disk per machine — which is
  exactly two machines' worth.
- **Wipe on the destination, not on pve.** A `blkdiscard` typo on the wrong
  `/dev/sdX` while the host is live is the single worst outcome available in
  this whole procedure. Boot the OptiPlex and wipe there.
- Check `Media_Wearout_Indicator` / `Percentage Used` from the pre-flight
  output before trusting them with anything that matters. Enterprise SATA
  SSDs with PLP, but they have been carrying a hypervisor root pool.
- **Thermals are the only thing that gets worse.** In the R730xd they sit at
  32°C in forced backplane airflow; an OptiPlex 2.5" bay has none, so expect
  40-50°C. Inside the 0-70°C spec, and the duty cycle there is far lighter
  than a hypervisor root pool, so lifetime is not the concern — but install
  `smartmontools` on each OptiPlex and check the temperature attribute once
  under load rather than assuming.
