# Beelink GTi13 Ultra — `pve-1`, `10.57.57.254`

Standalone Proxmox host, not clustered with pve. **Runs the entire Kubernetes
cluster** as `kubernetes-1` (VM 810 — 14 cores, 32 GiB, 350 GB, Iris Xe passed
through), plus Proxmox Datacenter Manager (VM 100).

Since 2026-09-01 this is the machine the homelab runs on. `pve-2` keeps the
disks: media and its NFS exports, the Garage S3 LXC that Longhorn backs into,
Nextcloud, and every backup leg. Losing `pve-2` costs media, Nextcloud and
backups but leaves the cluster running; losing this box stops everything.
There is no HA, deliberately —
[../../talos/SINGLE-NODE.md](../../talos/SINGLE-NODE.md).

**Memory budget** (62 GiB total): ZFS ARC 4, Proxmox ~2, PDM 8, `kubernetes-1`
44. VM 102 is stopped and does not count. Sizing the cluster VM below ~40 GiB
leaves pods `Pending` — total requests are 38 GiB.

| | |
|---|---|
| CPU / RAM | i9-13900HK (6P+8E, 20 threads), 62 GB DDR5 |
| `nvme1n1` | Proxmox root, LVM/ext4, `/local_data` for ISOs. **1% worn** |
| `nvme0n1` | ZFS `cluster-storage`, single disk, no redundancy. **33% worn**, 67 TB written |
| Network | 2x 2.5 GbE Intel I226 (`enp89s0` in use, `enp90s0` unused). Links at **1 GbE** — the switch is the ceiling, not the NIC |
| GPU | Iris Xe, bound to `vfio-pci`, passed to VM 810 |
| Power | 0.83 W package idle after tuning |

**Both NVMe are Crucial P3 Plus — QLC, DRAM-less.** The split matters: the OS
is on `nvme1n1` (1% worn), and `cluster-storage` — etcd and every Longhorn
volume — is on `nvme0n1`, which has burned a third of its endurance. Keep it
that way. Putting VM images on the OS disk means one failure takes both
Proxmox and the cluster.

Measured 2026-09-01: 67 TB written over 10,987 power-on hours ≈ 147 GB/day,
leaving ~153 TB and therefore roughly **three years**. Not urgent. A TLC
replacement is worth doing for etcd fsync latency rather than for endurance,
and it is the precondition for ever holding a second Longhorn replica here.

## BIOS

**Nothing else records these.** A cleared CMOS undoes every line below and the
only symptom is higher power draw. AMI Aptio 2.22.1289, changed 2026-09-01
unless noted.

| Path | Setting | Value | Why |
|---|---|---|---|
| Chipset → SA → Graphics | `Internal Graphics` | `Enabled` (was `Auto`) | Headless, no monitor attached. On `Auto` the firmware may disable the iGPU, and then there is no QuickSync to pass through |
| Chipset → SA → Graphics | `Primary Display` | `IGFX` | unchanged |
| Chipset → SA | `VT-d` | `Enabled` | unchanged — required for passthrough |
| Chipset → PCH-IO → PCI Express | `DMI Link ASPM Control` | `L1` (was `Disabled`) | The CPU↔PCH link never entered a low-power state. Also gates the deep package C-states. L0s on DMI buys nothing and has a bad history |
| Chipset → PCH-IO | `State After G3` | `S0` | unchanged — the box must power itself back on after an outage |
| Advanced → Thunderbolt | `ITBT RTD3` | `Enabled` (was `Disabled`) | The TB controller could never enter runtime D3, drawing power around the clock |
| Advanced → Thunderbolt | `Wake From Thunderbolt Devices` | `Disabled` (was `Enabled`) | Headless node, nothing should wake it over USB4 |
| Advanced → Connectivity | `Wi-Fi Core`, `BT Core` | `Disabled` (was `Enabled`) | Unused radios, powered for nothing |
| Advanced → Power & Perf → CPU PM | `C states`, `Enhanced C-states` | `Enabled` | unchanged — already correct |
| Advanced → Power & Perf → CPU PM | `Package C State Limit` | `Auto` | unchanged |
| Advanced → Power & Perf → CPU PM | `Platform PL1/PL2 Enable` | `Disabled` | Left off on purpose. Power limits are set from the OS via RAPL, where they are reversible and measurable |
| Advanced → Power & Perf → CPU PM | `Config TDP` | `54W` | unchanged. Three cTDP levels exist (ratio 26 / 20 / 30) if a lower cap is ever wanted |
| Advanced → Thermal | `Intel Dynamic Tuning` | `Disabled` | unchanged — DPTF has no business managing a server's thermals |

Verified after boot: `intel_idle` exposes C1 / C6 / C10, and the package sits
in C10 about 97% of the time at idle.

**Left off on purpose:** ASPM on the two I226 NICs (I226 + ASPM flaps links,
and `enp89s0` is the only path to the network) and on the NVMe (the drives
report `Exit Latency L1 unlimited`, so the kernel declines it anyway — forcing
it is how DRAM-less QLC starts timing out). Disabling the unused `enp90s0` in
BIOS would save under a watt; not worth a trip.

## What this directory deploys

`etc/` mirrors real paths on the host. Copy a file, then do the thing in the
last column.

| File | Host path | After copying |
|---|---|---|
| `etc/systemd/system/cpu-power.service` | same | `systemctl daemon-reload && systemctl enable --now cpu-power` |
| `etc/nut/nut.conf` | same | `apt install nut-client` **first** — see NUT below |
| `etc/nut/upsmon.conf` | same | password is redacted here, fill it in from pve-2 |
| `etc/modprobe.d/vfio.conf` | same | `update-initramfs -u` and reboot |
| `etc/modprobe.d/blacklist.conf` | same | as above |
| `etc/modprobe.d/zfs.conf` | same | ARC capped at 4 GB |
| `etc/modules` | same | as above |
| `etc/default-grub` | the `GRUB_CMDLINE_*` lines of `/etc/default/grub` | `update-grub` and reboot |

There is no drift check for this host. pve-2 has one because it carries dozens
of files and every backup script; eight files did not justify a second
mechanism. Add one if this grows.

## CPU power policy

The Proxmox kernel is built `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y`
(Debian stock gives `powersave`), so every boot starts on the performance
governor. Nothing on the host was setting it — it is the compiled-in default,
and cpufreq attributes are sysfs, so there is no config file to fix it in.
Hence `cpu-power.service`. Package idle **2.08 W → 0.83 W**.

`powersave` is not a low-frequency governor here: `intel_pstate` is in active
mode, so the CPU still reaches full turbo. Order matters inside the unit —
while the governor is `performance`, EPP writes are silently discarded.

## GPU passthrough

Already wired, left from when this host ran the Intel setup before 2026-07-17.
The iGPU is alone in IOMMU group 0 and bound to `vfio-pci` by
`etc/modprobe.d/vfio.conf` (`ids=8086:a7a0,8086:51ca`), with `i915` blacklisted.
Attaching it to a VM is one line:

```bash
qm set 810 --hostpci0 0000:00:02.0
```

The VM needs `--machine q35` and `--bios ovmf`. Inside the guest the device
appears at `0000:06:10.0`.

## NUT

The CyberPower VP700ELCD is on **pve-2's** USB. pve-1 is on the same UPS but has
no data connection to it, so without this it takes a hard cut on every mains
failure while pve-2 shuts down cleanly — the worst case for ZFS on QLC.

Proxmox does **not** ship NUT: this host had no `nut` package, no `/etc/nut`
and no `upsc` until 2026-09-01. Install `nut-client` before copying anything —
`nut-server` is not wanted here, there is no UPS on this machine's USB.

`nut.conf` here is `MODE=netclient`: upsmon only, no driver, no upsd. It
monitors `cyberpower@10.57.57.250` as a slave and shuts this host down on
battery. Coming back up needs nothing *from this host* — `State After G3` is
`S0`, verified by hand on 2026-09-03: unplug the cord with the box shut down,
plug it back in, it boots.

⚠️ That is not enough on its own. On 2026-09-03 a real power cut took both hosts
down cleanly and only pve-2 came back; this one sat off for 46 minutes. `S0` needs
a G3 to act on, and NUT was shutting the hosts down without ever telling the UPS
to cut its own output — so there was no power cycle to react to. Fixed on the
pve-2 side, in `proxmox/pve-2/etc/nut/` (`offdelay`/`ondelay`, `POWERDOWNFLAG`,
`POWEROFF_WAIT`). **Not yet proven by a drill** — the battery was at 18% that
night.

Verify from this host, not from pve-2 — a working `upsc` here proves the whole
path, listener and credentials included:

```bash
upsc cyberpower@10.57.57.250 ups.status     # expect OL
```

pve-2 logs the login as `User upsslave@10.57.57.254 logged into UPS`. The
`nut-common-tmpfiles.conf` warning in `journalctl -u nut-monitor` is a Debian
packaging artefact and is harmless.

pve-2 serves it via `proxmox/pve-2/etc/nut/{nut.conf,upsd.conf,upsd.users}`:
`MODE=netserver`, a `LISTEN` on the LAN address, and an `upsslave` user. That
password guards read-only status on the LAN and nothing else — if lost,
generate a new one and write it into both files.

## Related

[../pve-2/README.md](../pve-2/README.md) ·
[../../talos/talconfig.yaml](../../talos/talconfig.yaml) ·
[../../docs/operations.md](../../docs/operations.md) — adding a worker node
