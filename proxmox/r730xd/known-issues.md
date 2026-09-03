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

## The fans idle at 3800 RPM because that is iDRAC's honest answer

Every thermal knob iDRAC has was already at its quietest by 2026-08-27, and
the fans still ran at 3720-3840 RPM with the room at 27 °C, the disks parked
and the CPU at 41 °C:

```sh
racadm get system.thermalsettings        # on 10.57.57.249
ThermalProfile=Minimum Power             # the obvious lever, already pulled
FanSpeedOffset=Off                       # nothing added on top of baseline
MinimumFanSpeed=255                      # sentinel for unset: no artificial floor
ThirdPartyPCIFanResponse=Disabled        # the blind PCIe ramp, already off
AirExhaustTemp=70                        # real exhaust 35 °C, ceiling never engaged
```

`MinimumFanSpeed` is a floor, not a ceiling — it can only make the box louder.
There is no supported setting anywhere that asks for *less* air than the
algorithm wants, and what it wants for a 2U chassis with twelve spinning SAS
drives in front of it is ~3800 RPM whether or not those drives are spinning.

⚠️ **Read `racadm get`, not the OEM IPMI byte.**
`ipmitool raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00` returns
`16 05 00 00 00 05 00 01 00 00` on this host. That `0x01` was once read as
"Maximum Performance" and produced a recommendation to switch to a profile
that was already active. The byte mapping is not reliable; `racadm` is.

What the fans will actually do, measured 2026-09-03 through
`ipmitool raw 0x30 0x30 0x02 0xff <pct>` at inlet 27 °C:

| PWM | 0% | 1% | 2% | 4% | 5% | 8% | 10% | 12% | 15% | iDRAC auto |
|---|---|---|---|---|---|---|---|---|---|---|
| RPM | 1680 | 1740 | 2040 | 2400 | 2400 | 2900 | 3320 | 3600 | 4060 | 3720-3840 |

Two things fall out of that table. iDRAC's idle choice is about 12%, and the
hardware floor is 1680 RPM — less than half of it. Fan noise goes as
`50·log10(rpm ratio)`, so 3840 → 1680 is roughly **-18 dB**, and nothing else
on this host moves the noise floor anywhere near that far.

Fourteen minutes at 1680 RPM, same conditions, says the air is there: CPU
43 → 48 °C, hottest drive 34 → 36 °C, exhaust 35 → 39 °C, and the ROC 63 → 70 °C
where it plateaued by minute nine and stayed. Half the air costs about 7 °C on
the hottest part in the chassis, and leaves it 30 °C below anything that would
worry it.

The cost is that manual mode switches off the dynamic response, so something
else has to be it: [`scripts/fan-control.sh`](scripts/fan-control.sh), run by
`fan-control.service`. It watches CPU, hottest drive and the PERC's ROC, walks
a four-rung ladder, and hands cooling back to iDRAC above the top rung, in a
warm room, on an unreadable sensor and on exit. The ROC is in there because it
is the hottest thing in the chassis by a wide margin — 61-63 °C while the CPU
sits at 41 °C — and it is fed by exactly the airflow this turns down.

The electrical saving is ~2-4 W, inside the measurement noise on a host that
swings 116-287 W. This is an acoustic change and only an acoustic change — do
not reopen it as a power one. At 112 W with the pool parked, package and RAM
account for 29 W of it; the other 83 W is fixed iron.
