# pve (R730xd) — reinstall from bare metal

Host only. The cluster on top is [`DR.md`](../../DR.md).

[`reinstall.sh`](reinstall.sh) does everything scriptable. This page is the rest.

**Need:** Proxmox ISO · iDRAC or crash cart · this repo · `age.key` · restic
password. The last two are unrecoverable from any backup.

**Survives:** `media` (12× SAS) — import, never recreate.
**Does not:** `rpool`, taking `rpool/garage-meta` and the Garage LXC with it.

## 1. Firmware

PERC H730P → **HBA mode**. Otherwise ZFS sees virtual disks.

## 2. Install

`rpool` = ZFS mirror, the two 960GB Intel SSDs in slots 0–1.
`pve` · `10.57.57.250/24` · gw `10.57.57.1`.
Network: match [`etc/network-interfaces`](etc/network-interfaces) — `vmbr0`
bridges `nic3`, the rest stay manual.

```bash
zpool import -f media
```

## 3. Restore /root — before the script

Only the restic leg carries `/root`: SSH keys, healthcheck URLs, `PRIVATE-NOTES.md`.

```bash
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
restic restore latest --target / --include /root
```

Unreachable? Copy [`scripts/`](scripts/) from this repo and paste the
`hc-ping.com` UUIDs by hand.

Re-add the VPS push key to `/root/.ssh/authorized_keys` — line in
[`README.md`](README.md). `from=` must be `10.57.57.1`; pfSense NATs the
Tailscale traffic, so pve never sees the VPS's Tailscale address.

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

## 5. etcd credential

Not in git, not in any backup — it is a credential. One year TTL, and nothing
warns you when it lapses; the job just fails into its log.

```bash
talosctl -n 10.57.57.80 config new --roles os:etcd:backup \
  --crt-ttl 8760h /root/.talos-etcd-backup
chmod 600 /root/.talos-etcd-backup
```

`talosctl reboot` with it must return `PermissionDenied`. If the node reboots,
you made an admin config and put it on the backup host.

## 6. Nextcloud borg key

The script makes the user and dirs. The key is manual — AIO generates it on
first backup and shows it in its UI. Without the forced command it is a shell
login on this host.

```
command="borg serve --restrict-to-repository /media/backups/nextcloud",restrict ssh-ed25519 AAAA…
```

`0600`, owned by `borg-nextcloud`. Verify from the VM — borg should answer,
not a shell:

```bash
ssh -i <aio key> borg-nextcloud@10.57.57.250   # → "Borg 1.4.0: Got connection close…"
```

## 7. Garage LXC (103)

Stateless, so rebuilt:

```bash
cd <repo>/vps
ansible-playbook -i inventories/production/hosts playbooks/garage-setup-r730xd.yml
```

Data survived on `media/backups/longhorn-garage/data`. Meta was on `rpool` —
copy it back from `media/backups/longhorn-garage/meta/` (mirrored nightly at
03:01), then re-point Longhorn at the new key (`minio-secret.sops.yaml`).

## 8. VMs

| VM | How |
|---|---|
| 800 Talos CP | [`dr-quickstart.md`](../../docs/dr-quickstart.md) — one node |
| 1000 nextcloud | Its borg archive — [`nextcloud/README.md`](nextcloud/README.md) §6 |
| 105 ollama | Rebuilt: [`README.md`](README.md#ollama-vm). Keep `10.57.57.90`, n8n addresses it directly |
| 101 home-assistant | **No backup** since 2026-08-29. Put it in scope if you want it |

## 9. Two crontab caveats

The weekly Synology line is redacted in git — its schedule reveals the NAS wake
window. Restore it from `PRIVATE-NOTES.md`, inside that window.

No `CRON_TZ`: Debian's cron ignores it silently, so jobs keep local time while
looking moved. Tried 2026-08-20, reverted next morning — it put restic ahead of
its sources.
