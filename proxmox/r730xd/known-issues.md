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
SES enclosure, or a PID fan controller in manual mode. The first is the only
one that does not trade away a safety mechanism.
