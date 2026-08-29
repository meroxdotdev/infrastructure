# pve (R730xd) — reinstall from bare metal

Rebuilds the *host*. The K8s cluster on top is [`DR.md`](../../DR.md).

[`reinstall.sh`](reinstall.sh) does everything scriptable — packages, storage,
exports, ZFS properties, crontab, spin-down, the borg receiver, and a final
verify. This page is only the parts it cannot do, and why.

```bash
./reinstall.sh --check    # what it would do
./reinstall.sh            # do it
```

**You need:** the Proxmox ISO, iDRAC or a crash cart, this repo, and two
secrets that no backup can return — `age.key` (decrypts everything SOPS) and
the restic repo password (decrypts the Oracle leg). Lose the latter and you
are left with the Synology relay and the ZFS snapshots, both on hardware in
the same building.

**Survives:** the `media` pool, 12× SAS. Import it, do not recreate it.
**Does not:** `rpool` — and with it `rpool/garage-meta` and the Garage LXC.

## Before installing

The PERC H730P must be in **HBA mode**, set in firmware. Otherwise ZFS sees
virtual disks instead of drives. See [`spindown-setup.md`](spindown-setup.md).

## Install

`rpool` as a ZFS **mirror** across the two 960GB Intel SSDs in backplane slots
0–1. Hostname `pve`, `10.57.57.250/24`, gateway `10.57.57.1`. Then match
[`etc/network-interfaces`](etc/network-interfaces): `vmbr0` bridges `nic3`,
`nic0`–`nic2` stay manual.

```bash
zpool import        # confirm media is seen, 2x raidz2-6
zpool import -f media
```

## Restore /root before running the script

The restic repo is the only leg carrying `/root`, and it holds the SSH keys,
the healthcheck URLs and `PRIVATE-NOTES.md` that everything else needs.

```bash
export RESTIC_REPOSITORY="sftp:oracle-vps-restic:/data"
restic restore latest --target / --include /root      # prompts for the password
```

If restic is unreachable, copy [`scripts/`](scripts/) from this repo instead
and paste the `hc-ping.com` UUIDs back by hand.

Then re-add the VPS's restricted push key to `/root/.ssh/authorized_keys`. The
`rrsync` line is in [`README.md`](README.md), and `from=` must be
`10.57.57.1` — pfSense NATs the Tailscale traffic, so pve never sees the VPS's
Tailscale address.

**Now run `./reinstall.sh`.**

## etcd snapshot credential

`etcd-snapshot.sh` needs `/root/.talos-etcd-backup`: a Talos config carrying
**only** the `os:etcd:backup` role. It is not in this repo and not in any
backup, because it is a credential — and it is cheap to reissue.

```bash
talosctl -n 10.57.57.80 config new --roles os:etcd:backup \
  --crt-ttl 8760h /root/.talos-etcd-backup
chmod 600 /root/.talos-etcd-backup
```

Confirm the scope took: `talosctl reboot` with this config must return
`PermissionDenied`. If it reboots the node, you generated an admin config and
put it on the backup host.

The cert lasts one year. Nothing warns you when it lapses — the snapshot job
simply starts failing into its log.

## Nextcloud borg key

`reinstall.sh` creates the user, the dataset and the directories. The key
itself is authorised by hand, because AIO generates it on its first backup
attempt and prints it in its own interface. The forced command is not
optional — without it the key is a general-purpose shell login on this host:

```
command="borg serve --restrict-to-repository /media/backups/nextcloud",restrict ssh-ed25519 AAAA…
```

`0600`, owned by `borg-nextcloud`. Verify from the VM before trusting it —
borg should answer, not a shell:

```bash
ssh -i <aio key> borg-nextcloud@10.57.57.250   # → "Borg 1.4.0: Got connection close…"
```

## VMs

| VM | How it comes back |
|---|---|
| 800 Talos control plane | [`docs/dr-quickstart.md`](../../docs/dr-quickstart.md) — one node, not three |
| 1000 nextcloud | From its own borg archive on the `media` pool — [`nextcloud/README.md`](nextcloud/README.md) §6 |
| 105 ollama | Rebuilt, not restored. The model is a re-fetchable cache; the steps are in [`README.md`](README.md#ollama-vm). Keep IP `10.57.57.90` — n8n's alert-triage workflows address it directly |
| 101 home-assistant | **Not backed up.** Its nightly dump was retired on 2026-08-29: the VM was stopped, out of DR scope, and the dump never left the host. If you want it protected, put it in scope rather than reviving the dump |

## Garage LXC (103)

Rebuilt, not restored — the container is stateless.

```bash
cd <repo>/vps
ansible-playbook -i inventories/production/hosts playbooks/garage-setup-r730xd.yml
```

Its **data** is the bind mount on `media/backups/longhorn-garage/data` and
survived. Its **meta** lived on `rpool` and did not — copy it back from
`media/backups/longhorn-garage/meta/`, which the 03:01 job mirrors nightly.
Then re-point Longhorn at the new key (`minio-secret.sops.yaml`).

## Two things the crontab cannot carry

The weekly Synology line is **redacted in git** — its schedule reveals the NAS
wake window. Add it back from `/root/PRIVATE-NOTES.md`, inside that window,
which DSM keeps in its own local time.

And do not add `CRON_TZ`. Debian's cron does not implement it: the line parses
as an ordinary environment assignment and is ignored, so every job keeps its
local meaning while looking like it was moved. Tried 2026-08-20, reverted the
next morning — it had put restic ahead of every source that feeds it.
