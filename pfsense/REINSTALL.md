# pfSense (`fw.merox.dev`, 10.57.57.1) — reinstall

Checklist, not a tutorial.

Gateway, DHCP and Tailscale subnet router. Losing it takes down the LAN
**and** remote access at once — plan for console access, not SSH.

**You need:**

- pfSense installer
- a config from `/media/backups/pfsense/` on pve-2 (nightly, 30-day retention)
- physical or serial console access

## What a config restore does not cover

`config.xml.gz` restores rules, interfaces, packages, and the **cron
entry** for the nightly backup. It restores nothing under `/root`:

| Item | In `config.xml`? |
|---|---|
| Cron entry calling the backup script | ✅ yes |
| `/root/scripts/backup.sh` | ❌ no |
| `/root/.ssh/pfsense-backup` (private key) | ❌ no |

Net effect: a restored pfSense firewalls perfectly while its own backup
calls a missing script and fails silently — every later config frozen at
rebuild day. Steps 3 and 4 exist for this.

## 1. Install and restore the config

Install pfSense, then Diagnostics → Backup & Restore → restore
`backups/pfsense/config.xml.gz` from the NAS (gunzip first if the UI wants
plain XML). An older version: the vault's snapshots, or until phase 7 the dated
copies in `/media/backups/pfsense/` on pve-2. Reboot.

## 2. Confirm the basics before moving on

Gateway `10.57.57.1`, DHCP handing out leases, WAN up, and the Tailscale
subnet router advertising `10.57.57.0/24`.

DNS, as the restored config should have it (set 2026-10-02):

- Host overrides: eight names under `merox.dev` — `fw`, `nas`, `vault`,
  `idrac`, `pve-1`, `pve-2`, `pve-3`, `dc`. Nothing else.
- One domain override: `k8s.merox.dev` → `10.57.57.111`, the cluster's
  k8s-gateway, which answers every `*.k8s` name itself. No per-app entries.
- Unbound outgoing interfaces: **LAN and WAN**. WAN alone sends the override's
  queries from the public address, and k8s-gateway never answers them.
- System DNS servers: public resolvers only. k8s-gateway answers its own zone
  and refuses everything else, so it is never a general resolver.
- LAN DHCP pool `.202-.239`, below every static server address: the vault is
  off most of the day, and a pool that included `.250` would hand its address
  away.

```sh
drill @10.57.57.1 grafana.k8s.merox.dev   # 10.57.57.101
drill @10.57.57.1 vault.merox.dev         # 10.57.57.250
``` UDP 41641 must be forwarded
WAN → `10.57.57.1:41641` — see
[`docs/jellyfin-post-restore.md`](../docs/jellyfin-post-restore.md).

## 3. Put the backup script back

```sh
mkdir -p /root/scripts
# copy from this repo: pfsense/scripts/backup.sh
chmod 700 /root/scripts/backup.sh
```

## 4. New SSH key, and authorise it on the NAS

The old private key is gone and is not worth recovering — generate a fresh
pair:

```sh
ssh-keygen -t ed25519 -f /root/.ssh/pfsense-backup -N "" -C "pfsense-backup"
cat /root/.ssh/pfsense-backup.pub
```

On the NAS it is the only line in the `pfsense` user's
`/volume1/homes/pfsense/.ssh/authorized_keys`, owned by `pfsense`, mode 600
(installing it needs root once — see [synology/README.md](../synology/README.md#users)):

```
restrict,from="10.57.57.1" ssh-ed25519 <new pubkey> pfsense-backup
```

Until phase 7 the script also pushes to pve-2. There, add **one** line to
`/root/.ssh/authorized_keys` — the forced command is what limits this key to
dropping files in one directory:

```
command="/root/pfsense-backup-receive.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 <new pubkey> pfsense-backup-to-r730xd
```

⚠️ Exactly one line for this key. Two lines with the same key means SSH
uses the first and silently ignores the second — that is how the 30-day
prune sat dead until 2026-08-11. Pattern in
[`proxmox/pve-2/etc/authorized_keys`](../proxmox/pve-2/etc/authorized_keys);
receiver in
[`proxmox/pve-2/scripts/pfsense-backup-receive.sh`](../proxmox/pve-2/scripts/pfsense-backup-receive.sh).

## 5. Verify the loop actually closes

```sh
/root/scripts/backup.sh && echo OK     # on pfSense
```

```bash
ls -1t /media/backups/pfsense/ | head -2          # on pve-2 — a fresh timestamp
```

Not done until a file with today's timestamp appears on pve.
