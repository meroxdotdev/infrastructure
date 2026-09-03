# pve (R730xd) — known issues & fixes

Forensic record for hardware/OS quirks on this host — read it before
"simplifying" something that looks like unnecessary complexity in
[README.md](README.md).

Back to the host reference: [README.md](README.md).

## Why NUT, not PowerPanel, for the UPS

The UPS (CyberPower VP700ELCD) is on pve's own USB, monitored by NUT
(`upsmon` shuts the host down locally on low battery — see
[README.md](README.md#ups-triggered-shutdown) for the operational config).
`powerpanel` was tried first and is now masked/disabled — leave it that way,
the two fight over the same device.

**This is the load-bearing detail, do not "simplify" it back.** The R730xd is
**EHCI-only**: `lspci` shows two Enhanced Host Controllers and no xHCI at
all, and every external port sits behind an internal hub. This UPS is a
*low-speed* (1.5 Mbps) HID device, so it reaches the CPU through the hub's
transaction translator, and there it re-enumerates on a metronomic
8-seconds-up / 3-seconds-down cycle. Verified 2026-08-17:

- identical on both EHCI controllers (`00:1a.0` and `00:1d.0`)
- identical with the monitoring daemon running *and* stopped — 17 events in
  90 s with nothing at all holding `/dev/usb/hiddev0`
- **zero USB errors** in `dmesg`; a bad cable or port throws `-71`/`-110`,
  this throws nothing
- the same UPS and cable were stable on a different host with xHCI, isolating
  the cause to this chassis's EHCI-only USB controllers

`pwrstatd` (PowerPanel) talks to `/dev/usb/hiddev0` and cannot survive that
churn: it reported only `State: Normal` and never once read battery charge,
runtime or load — so `lowbatt-threshold` and `runtime-threshold` had nothing
to fire on. NUT's `usbhid-ups` goes through **libusb**, reconnects across
each re-enumeration and reads the full variable set. The device still flaps;
it simply stopped mattering.

## Drives without SES temperature reporting make the fans scream

A consumer SSD added to the backplane took every fan from ~3200 to ~8900 RPM
and added 16 W, while the chassis stayed cold — inlet 25 °C, exhaust 28 °C,
CPU 40 °C. Nothing was overheating; the fans were guessing.

The backplane (`BP13G+EXP`) has **no temperature sensors of its own**
(`TSs=0` in `storcli /c0/eall show`). Every thermal reading from the front of
the chassis comes from the drives themselves. One drive that will not answer
leaves the algorithm blind, so it assumes the worst and ramps everything.

Diagnosis, in one command:

```sh
for s in 0 1 16; do storcli /c0/e32/s$s show all | grep "Drive Temperature"; done
```

A healthy drive answers `25C`. The offender answered `N/A`. Reading deeper:

```sh
sg_logs --temperature /dev/sdX     # Current temperature = 255 C   -> 0xFF, invalid
smartctl -A /dev/sdX | grep -i temp # 26                           -> sensor works fine
```

The drive has a working sensor and reports it over ATA SMART, but returns the
invalid sentinel on the SCSI log page the backplane queries. Enterprise drives
in the same chassis — including four non-Dell Intel SSDs — answer correctly,
so "third-party" is not the criterion. Answering is.

What does not help: another slot (all 24 sit behind the same SES expander),
formatting, or `ThirdPartyPCIFanResponse`. That last one governs PCIe cards,
and the Quadro in this box is already invisible to iDRAC
(`PCIe Slot1-4 = Not Readable`) without ever having caused a ramp — proof the
lever is not connected to this problem.

There is no official Dell fix; their guidance is to use certified drives. The
options are a drive that reports temperature, an onboard SATA port outside the
SES enclosure, or manual fan control. The first is the only one that does not
trade away a safety mechanism, and it is what was done here — every drive in
the chassis reports temperature again.

Manual control arrived later anyway, for the ordinary idle noise rather than
for a blind ramp: see the next section.

## Fan noise: iDRAC's floor is ~3800 RPM, the hardware's is 1680

Every thermal knob was already at its quietest by 2026-08-27 and the fans still
ran 3720-3840 RPM at inlet 27 °C, disks parked, CPU 41 °C:

```sh
racadm get system.thermalsettings        # on 10.57.57.249
ThermalProfile=Minimum Power
FanSpeedOffset=Off
MinimumFanSpeed=255                      # sentinel for unset
ThirdPartyPCIFanResponse=Disabled
AirExhaustTemp=70                        # real exhaust 35 °C
```

`MinimumFanSpeed` is a floor, not a ceiling. No supported setting asks for less
air than the algorithm wants.

⚠️ **Read `racadm get`, not the OEM IPMI byte.** `ipmitool raw 0x30 0xce 0x01
0x16 0x05 0x00 0x00 0x00` returns `16 05 00 00 00 05 00 01 00 00`; that `0x01`
was once misread as "Maximum Performance" and produced a recommendation for a
profile that was already active. The byte mapping is not reliable.

### Measured, 2026-09-03, inlet 27 °C

`ipmitool raw 0x30 0x30 0x02 0xff <pct>`, all six fans:

| PWM | 0% | 1% | 2% | 4% | 5% | 8% | 10% | 12% | 15% | auto |
|---|---|---|---|---|---|---|---|---|---|---|
| RPM | 1680 | 1740 | 2040 | 2400 | 2400 | 2900 | 3320 | 3600 | 4060 | 3720-3840 |

iDRAC's idle choice is ~12%. Noise goes as `50·log10(rpm ratio)`, so
3840 → 1680 is about **-18 dB** — on the fans alone; drives and PSU are
unchanged.

14 minutes at 1680 RPM, everything settled and stopped:

| | start | end | limit |
|---|---|---|---|
| CPU | 43 °C | 48 °C | 78 Tcase |
| Hottest drive (parked) | 34 °C | 36 °C | 55-60 |
| PERC ROC | 63 °C | **70 °C, plateau at min 9** | ~100 throttle |
| Exhaust | 35 °C | 39 °C | 70 (AirExhaustTemp) |

The plateau is the evidence: heat in equals heat out with 30 °C to spare on the
hottest part.

### What runs it

[`scripts/fan-control.sh`](scripts/fan-control.sh) under `fan-control.service`.
Ladder, sensors and failure paths are documented in the script header and in
[README.md](README.md#fan-control).

Not a power change: ~2-4 W, inside the measurement noise on a host that swings
116-287 W.
