# pfSense (`fw.merox.dev`, 10.57.57.1) — reinstall

Checklist, not a tutorial.

pfSense is the gateway, DHCP server and Tailscale subnet router. Losing it
takes down the LAN **and** remote access at the same time — it is the one
device whose failure removes the hands you would fix everything else with.
Plan for console access, not SSH.

**You need:** the pfSense installer, a config from
`/media/backups/pfsense/` on pve (nightly, 30-day retention), and physical
or serial console access.

## The part a config restore does not cover

`config.xml.gz` restores the firewall completely — rules, interfaces,
packages, and the **cron entry** that runs the nightly backup. It does not
restore anything under `/root`:

| Item | In `config.xml`? |
|---|---|
| Cron entry calling the backup script | ✅ yes |
| `/root/scripts/backup-to-r730xd.sh` | ❌ no |
| `/root/.ssh/pfsense-backup` (private key) | ❌ no |

So a restored pfSense firewalls perfectly while its own backup runs a
missing script and fails silently. The next config you have is frozen at
the day of the rebuild. Steps 3 and 4 exist for exactly this.

## 1. Install and restore the config

Install pfSense, then Diagnostics → Backup & Restore → restore the newest
`config-*.xml.gz` from `/media/backups/pfsense/` on pve (gunzip first if
the UI wants plain XML). Reboot.

## 2. Confirm the basics before moving on

Gateway `10.57.57.1`, DHCP handing out leases, WAN up, and the Tailscale
subnet router advertising `10.57.57.0/24`. UDP 41641 must be forwarded
WAN → `10.57.57.1:41641` — see
[`docs/jellyfin-post-restore.md`](../docs/jellyfin-post-restore.md).

## 3. Put the backup script back

```sh
mkdir -p /root/scripts
# copy from this repo: pfsense/scripts/backup-to-r730xd.sh
chmod +x /root/scripts/backup-to-r730xd.sh
```

## 4. New SSH key, and authorise it on pve

The old private key is gone and is not worth recovering — generate a fresh
pair:

```sh
ssh-keygen -t ed25519 -f /root/.ssh/pfsense-backup -N "" -C "pfsense-backup-to-r730xd"
cat /root/.ssh/pfsense-backup.pub
```

On pve, add **one** line to `/root/.ssh/authorized_keys` — the forced
command is what limits this key to dropping files in one directory:

```
command="/root/pfsense-backup-receive.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 <new pubkey> pfsense-backup-to-r730xd
```

⚠️ Exactly one line for this key. Two lines with the same key means SSH
uses the first and silently ignores the second — that is how the 30-day
prune sat dead until 2026-08-11. Pattern in
[`proxmox/r730xd/etc/authorized_keys`](../proxmox/r730xd/etc/authorized_keys);
receiver in
[`proxmox/r730xd/scripts/pfsense-backup-receive.sh`](../proxmox/r730xd/scripts/pfsense-backup-receive.sh).

## 5. Verify the loop actually closes

```sh
/root/scripts/backup-to-r730xd.sh && echo OK     # on pfSense
```

```bash
ls -1t /media/backups/pfsense/ | head -2          # on pve — a fresh timestamp
```

Not done until a file with today's timestamp appears on pve. A restored
firewall that cannot back itself up is the failure this page exists to
prevent.
