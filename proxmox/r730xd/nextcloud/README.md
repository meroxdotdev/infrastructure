# Nextcloud (VM 1000)

As-built reference. Multi-user file service on `pve`, reachable from the
internet over a Cloudflare tunnel: per-user storage, shared folder, public
share links, in-browser office editing, TOTP 2FA. Built 2026-08-20.

Related: [../README.md](../README.md) · [../REINSTALL.md](../REINSTALL.md) ·
[../../../DR.md](../../../DR.md)

| In git | Deployed at |
|---|---|
| [`etc/docker-compose.yml`](etc/docker-compose.yml) | `/opt/nextcloud/` — AIO mastercontainer |
| [`etc/cloudflared-compose.yml`](etc/cloudflared-compose.yml) | `/opt/cloudflared/` — tunnel, separate stack |
| [`etc/99-cloudflared-quic.conf`](etc/99-cloudflared-quic.conf) | `/etc/sysctl.d/` — UDP buffers for QUIC |
| [`scripts/docker-lan-isolation.sh`](scripts/docker-lan-isolation.sh) | `/usr/local/sbin/` |
| [`etc/docker-lan-isolation.service`](etc/docker-lan-isolation.service) | `/etc/systemd/system/` — reapplies after Docker restarts |
| [`etc/fstab`](etc/fstab) | `/etc/fstab` |

Password manager only: the tunnel token (`/opt/cloudflared/.env`), the AIO
passphrase, the borg passphrase, the admin password.

## 1. Architecture

```
Internet
  └─ Cloudflare  (geo rule · login rate limit · TLS)
       └─ tunnel, outbound only — no ports forwarded on pfSense
            └─ cloudflared (host network)
                 └─ 127.0.0.1:11000
                      └─ AIO apache ─┬─ nextcloud
                                     ├─ postgresql
                                     ├─ redis
                                     ├─ collabora      (same hostname)
                                     ├─ imaginary      (HEIC/PDF previews)
                                     └─ notify-push
```

The compose file starts only the mastercontainer; AIO creates the rest.

Left off on purpose: Talk (needs 3478/UDP, which a tunnel cannot carry),
ClamAV and Fulltextsearch (~1 GB RAM each, for three users), Whiteboard, HaRP,
Docker Socket Proxy.

## 2. Storage

Three thin zvols on `rpool` (SSD mirror) — everything an app touches daily
lives on SSD, per the storage rule in [../README.md](../README.md).

| Disk | Size | Mount | Holds | Backed up |
|---|---|---|---|---|
| scsi0 | 50 G | `/`, `/var` | OS, Docker images and volumes | volumes only, via borg |
| scsi1 | 200 G | `/mnt/nextcloud-data` | user files (`NEXTCLOUD_DATADIR`) | **yes** |
| scsi2 | 50 G | `/mnt/nobackup` | External Storage mount `Fara-backup` | **no, by design** |

The 200 G volsize is a safety device: `rpool` also carries the Talos disks
including etcd, so a runaway upload without a ceiling could stall the cluster.

**`/var` is the 39 G partition, not the 2.8 G one.** The Debian installer split
the system disk `/` 6.9 G, `/var` 2.8 G, `/srv` 39 G — and this stack needs
15-20 GB under `/var`. Fixed by repurposing `/srv` as `/var` rather than
moving Docker's `data-root`, which would have meant two non-default paths:
Docker 29 uses the containerd image store, so images live under
`/var/lib/containerd`, which `data-root` does not move. The old 2.8 G partition
is still there, unmounted, its fstab line commented and dated — that is the
rollback.

## 3. Access

| Route | How |
|---|---|
| Public | the Cloudflare hostname, over the tunnel |
| AIO admin (8080) | `ssh -L 8080:127.0.0.1:8080 <host>` → `https://localhost:8080` |
| Files on disk | `/mnt/nextcloud-data/<user>/files/…` — plain files over SSH |

Port 8080 binds to loopback, and that is what protects it. ufw is not enough:
Docker DNATs published ports ahead of the ufw chains, so a `default deny
incoming` host still answers on every published port. Verified from another
VLAN. Only port 22 listens on the network.

## 4. Security

| Control | Note |
|---|---|
| No WAN ports opened | tunnel is outbound only; pfSense untouched |
| Admin interface on loopback | §3 |
| Containers cannot reach the LAN | `DOCKER-USER` rules, §5 |
| TOTP 2FA | Nextcloud built-in |
| Brute-force protection sees real client IPs | verified in the audit log — the client's address, not Cloudflare's |
| Login rate limit at the edge | Cloudflare, on POST to the login path |
| Geo rule | non-RO gets a managed challenge; share routes excepted so links work worldwide |
| Share links need a password, expire in 30 days | `shareapi_enforce_links_password`, `shareapi_expire_after_n_days` |
| Automatic updates | AIO backs up immediately before each one |

WAF expressions live in `/root/PRIVATE-NOTES.md` on pve, same convention as the
Synology wake window.

**No fail2ban, deliberately.** Behind a tunnel, a jail acting on web logs bans
Cloudflare's edge and locks out everyone including you — a total blackout with
no obvious cause. Cloudflare's own rate limiting runs where the client IP is a
fact rather than a header.

## 5. LAN isolation

This is the most exposed service in the homelab, and the LAN is flat — assume
the container is compromised and it reaches pfSense, the NAS, Proxmox and the
cluster.

[`docker-lan-isolation.sh`](scripts/docker-lan-isolation.sh) writes
`DOCKER-USER` rules dropping container traffic to RFC1918 destinations leaving
on the physical NIC, with two exceptions: DNS to pfSense, and SSH to pve for
borg. Container-to-container traffic and outbound internet are untouched. The
unit is `PartOf=docker.service`, so the rules survive Docker recreating its
chains.

```bash
docker exec nextcloud-aio-nextcloud timeout 6 curl -s http://<a-lan-host>/      # must fail
docker exec nextcloud-aio-nextcloud timeout 6 nc -z 10.57.57.250 22             # must succeed
docker exec nextcloud-aio-nextcloud timeout 10 curl -sI https://cloudflare.com  # must succeed
```

## 6. Backup

No new mechanism — Nextcloud is one more source in the existing mesh.

```
AIO borg (nightly, 23:40 UTC)
   └─ ssh://borg-nextcloud@pve/media/backups/nextcloud      encrypted, on SAS
        ├─ restic 00:10 UTC  → Oracle VPS                   encrypted, off-site
        └─ rsync weekly      → Synology                     cold, local
```

Borg captures every AIO volume (PostgreSQL, config, apps) **and** the datadir,
with containers stopped, so database and files stay consistent. It does not
capture `/mnt/nobackup` — that is the point of that disk.

The repository is owned by a dedicated `borg-nextcloud` account whose key is
pinned to `command="borg serve --restrict-to-repository …",restrict`.

Append-only was rejected: it blocks AIO's retention from reclaiming space and
forces a manual `borg compact` forever. A compromised Nextcloud can destroy the
borg repository but holds no credential for the restic repo or the Synology
relay — both are written *by pve*.

**Restore one file, without AIO.** Works anywhere borg is installed and the
repository is reachable — pve, or the Synology copy if pve is gone.

```bash
export BORG_PASSPHRASE='…'
borg list /media/backups/nextcloud                        # archives
borg list /media/backups/nextcloud::ARCHIVE | grep NAME
borg extract /media/backups/nextcloud::ARCHIVE 'exact/path'
```

Verified 2026-08-20: extracted byte-identical, and the archive held a file
already deleted from the live instance. Restoring the whole instance is a
button in AIO pointed at the same repository.

**After losing pve.** `rpool` holds both the OS and the VM disks, so a
reinstall takes the live data. `media` is on separate disks: `zpool import
media` brings the repository back. Rebuild the VM, install Docker and AIO,
point AIO's restore at it. Worst case is one night of files.
[../REINSTALL.md](../REINSTALL.md) covers the pve side, including recreating
the `borg-nextcloud` account — which does not survive a reinstall even though
its repository does.

## 7. Operations

- **Optional containers:** stop containers, change the selection, press *Save
  changes*, start. The save button is easy to miss and the selection is
  discarded silently without it.
- **Majors cannot be skipped.** AIO upgrades one at a time on container start.
- **Bulk import:** copy into the datadir, then `occ files:scan
  --path="<user>/files"`. Check first for names Nextcloud rejects — `\ < > : "
  | ? *`, trailing dot or space, `.htaccess` — the scan skips them silently.

## 8. Known limits

| Limit | Effect | Live with it by |
|---|---|---|
| Cloudflare free caps bodies at 100 MB | browser uploads above that fail with 413 | desktop/mobile clients chunk |
| AIO schedules in UTC, ignoring the configured timezone | in winter the backup lands an hour early and wakes the SAS pool separately | accepted; revisit in October |
| Cloudflare free allows one rate-limit rule | caps velocity rather than banning | 2FA and Nextcloud's own throttle carry the weight |
| Geo rule blocks the owner abroad | sync clients cannot answer a challenge | disable it while travelling |
| Files are ext4 inside a zvol | not readable from pve with `ls`, unlike the LXC design | §9 |

## 9. Why it looks like this

| Chose | Over | Because |
|---|---|---|
| Nextcloud | Seafile | Its block store is unreadable without the database — the disease that retired HyperBackup |
| Nextcloud | OpenCloud | Three majors between February and May 2026, and metadata in xattrs that one rsync leg would drop without `-X` |
| AIO in a VM | Hand-rolled compose in an LXC | AIO needs the Docker socket, unsupported in an unprivileged LXC. Brings tested backup/restore/update paths and serves Collabora on the main hostname |
| zvol | Longhorn | Longhorn holds small state like Immich and the ARR configs. Several hundred GB is a different question, and single-node with replica count 1 did not change the answer |

The cost of the VM: files were meant to stay readable from pve with `ls`. They
are still plain files, now on ext4 inside a zvol, reached over SSH to the VM.
The escape hatch survives, one hop longer.
