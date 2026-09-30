# pve-2 (R730xd) — reinstall from bare metal

Host only. The cluster on top is [`DR.md`](../../DR.md).

[`reinstall.sh`](reinstall.sh) does everything scriptable. This page is the rest.

**Need:** Proxmox ISO · iDRAC or crash cart · this repo · `age.key` · restic
password. The last two are unrecoverable from any backup.

**Survives:** `media` (12× SAS) — import, never recreate.
**Does not:** `rpool`, which holds nothing that is not rebuilt from this repo.

## 1. Firmware

PERC H730P → **HBA mode**. Otherwise ZFS sees virtual disks.

## 2. Install

`rpool` = ZFS mirror, the two 960GB Intel SSDs in slots 0–1.
`pve-2` · `10.57.57.250/24` · gw `10.57.57.1`.
Network: match [`etc/network-interfaces`](etc/network-interfaces) — `vmbr0`
bridges `nic3`, the rest stay manual.

```bash
zpool import -f media
```

## 3. Restore /root — before the script

Only the restic leg carries `/root`: SSH keys, healthcheck URLs, `PRIVATE-NOTES.md`.

Circular, and the way out is not on this host. Restoring `/root` needs a
credential to reach the repository, and every such credential lives in `/root`:
the old SFTP key did, `/root/.restic-rest-password` does now. So do not restore
`/root` from pve-2 — read the repository on the VPS, where the only secret is
the repo password from the password manager, and copy `/root` back over
Tailscale.

```bash
# on the VPS, as a sudoer
sudo docker run --rm -u 999:987 \
  -v /srv/restic-repo/data:/repo -v /etc/restic/repo-password:/pw:ro \
  -v /tmp/root-restore:/restore \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/pw \
  restic/restic:0.18.0 restore latest --include /root --target /restore
# then, from the rebuilt pve-2
rsync -a ubuntu@100.72.22.38:/tmp/root-restore/root/ /root/
```

Unreachable? Copy [`scripts/`](scripts/) from this repo and paste the
`hc-ping.com` UUIDs by hand.

Re-add the VPS push key to `/root/.ssh/authorized_keys` — line in
[`README.md`](README.md). `from=` must be `10.57.57.1`; pfSense NATs the
Tailscale traffic, so pve-2 never sees the VPS's Tailscale address.

## 4. Run it

```bash
./reinstall.sh --check
./reinstall.sh
```

Packages, storage, exports, ZFS reservation and quota, crontab, spin-down,
fan control, borg receiver, verify.

A freshly installed host is loud: iDRAC's algorithm asks for ~3800 RPM whatever
the temperatures are, and stays there until `fan-control.service` is enabled by
the step above. That is the expected order — never quiet before it is safe.

## 5. Two crontab caveats

The weekly Synology line is redacted in git — its schedule reveals the NAS wake
window. Restore it from `PRIVATE-NOTES.md`, inside that window.

No `CRON_TZ`: Debian's cron ignores it silently, so jobs keep local time while
looking moved. Tried 2026-08-20, reverted next morning — it put restic ahead of
its sources.

## 6. Monitoring token

`reinstall.sh` brings node_exporter back. The Proxmox API token pve-exporter
reads this host with does not: it lived in the old `/etc/pve`. Until it is
recreated the pve-2 scrape fails, and `PveNodeDown` and the storage alerts are
blind to this host.

Recreate it and put the new value in the **`default`** module of
`pve-exporter-secret` — pve-2's module is named `default`, not `pve-2`, for
historical reasons. The commands are in
[pve-exporter/README.md](../../kubernetes/apps/observability/pve-exporter/README.md#adding-a-host).
