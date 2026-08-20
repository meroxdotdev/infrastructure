# Nextcloud (VM 1000, `nextcloud`)

As-built reference for the Nextcloud instance on `pve`. Multi-user file
service reachable from the internet at a Cloudflare-tunnelled hostname, with
per-user storage, a shared folder, public share links, in-browser office
editing and TOTP 2FA.

Built 2026-08-20. Supersedes the earlier LXC + hand-rolled compose design —
§9 records what changed and why, so the reasoning is not lost.

Related: [../README.md](../README.md) (backup mesh) ·
[../REINSTALL.md](../REINSTALL.md) (rebuild pve) ·
[../spindown-setup.md](../spindown-setup.md) ·
[../../../DR.md](../../../DR.md)

Host state that is not a clean install lives in git — the host is the running
copy, these are the reviewable ones:

| In git | Deployed at | What |
|---|---|---|
| [`etc/docker-compose.yml`](etc/docker-compose.yml) | `/opt/nextcloud/` | AIO mastercontainer |
| [`etc/cloudflared-compose.yml`](etc/cloudflared-compose.yml) | `/opt/cloudflared/docker-compose.yml` | tunnel, separate stack |
| [`etc/99-cloudflared-quic.conf`](etc/99-cloudflared-quic.conf) | `/etc/sysctl.d/` | UDP buffers for QUIC |
| [`scripts/docker-lan-isolation.sh`](scripts/docker-lan-isolation.sh) | `/usr/local/sbin/` | LAN isolation rules |
| [`etc/docker-lan-isolation.service`](etc/docker-lan-isolation.service) | `/etc/systemd/system/` | re-applies them after Docker restarts |
| [`etc/fstab`](etc/fstab) | `/etc/fstab` | disk layout |

Not in git: `/opt/cloudflared/.env` (tunnel token), the AIO passphrase, the
borg passphrase, the Nextcloud admin password. Password manager only.

---

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

Nextcloud AIO manages its own containers; the compose file starts only the
mastercontainer. Everything else is created by it.

Optional containers deliberately left off: Talk (needs 3478/UDP, which a
tunnel cannot carry), ClamAV and Fulltextsearch (~1 GB RAM each, for three
users), Whiteboard, HaRP, Docker Socket Proxy.

## 2. Storage

Three disks, each with one job.

| Disk | Size | Mount | Holds | Backed up |
|---|---|---|---|---|
| scsi0 | 50 G | `/`, `/var` | OS, Docker images and volumes | via borg (volumes only) |
| scsi1 | 200 G | `/mnt/nextcloud-data` | user files (`NEXTCLOUD_DATADIR`) | **yes** |
| scsi2 | 50 G | `/mnt/nobackup` | External Storage mount `Fara-backup` | **no, by design** |

All three are thin-provisioned zvols on `rpool` (SSD mirror). That satisfies
the storage rule in [../README.md](../README.md): the SAS pool holds bulk
media and backups, everything an application touches during the day lives on
SSD.

The 200 G volsize is the safety device. `rpool` also carries the Talos VM
disks including etcd; without a ceiling a runaway upload could stall the
cluster. With it, a runaway Nextcloud fails on its own and nothing else
notices.

### `/var` sits on the 39 G partition, not the 2.8 G one

The Debian installer split the 50 G system disk into `/` 6.9 G, `/var` 2.8 G
and `/srv` 39 G. Docker keeps images and volumes under `/var`, and this stack
needs 15-20 GB — it would have filled `/var` partway through the first pull.

Fixed by repurposing the 39 G partition as `/var` and dropping `/srv`
entirely, rather than redirecting Docker's `data-root`. Redirection would have
meant **two** non-default paths, because Docker 29 here uses the containerd
image store and keeps images under `/var/lib/containerd`, which `data-root`
does not move. The partition swap leaves every path at its default and there
is nothing to remember during a rebuild.

The old 2.8 G partition is still present, unmounted, with its fstab line
commented and dated. It is the rollback.

## 3. Access

| Route | How |
|---|---|
| Public | the Cloudflare hostname, over the tunnel |
| Admin (AIO, port 8080) | `ssh -L 8080:127.0.0.1:8080 <host>`, then `https://localhost:8080` |
| Files on disk | `/mnt/nextcloud-data/<user>/files/…`, plain files, readable over SSH |

Port 8080 binds to loopback. It is **not** enough to rely on ufw here: Docker
DNATs published ports ahead of the ufw chains, so a `ufw default deny
incoming` host still answers on every published port. Verified from another
VLAN before and after the change.

Only port 22 listens on the network.

## 4. Security

| Control | Note |
|---|---|
| No WAN ports opened | the tunnel is outbound only; pfSense untouched |
| Admin interface on loopback | §3 |
| Containers cannot reach the LAN | `DOCKER-USER` rules, §5 |
| TOTP 2FA on accounts | Nextcloud built-in |
| Brute-force protection sees real client IPs | verified: the address in the audit log is the client's, not Cloudflare's |
| Login rate limit at the edge | Cloudflare, on POST to the login path |
| Geo rule | non-RO gets a managed challenge; public share routes are excepted so links work worldwide |
| Share links require a password, expire in 30 days | `shareapi_enforce_links_password`, `shareapi_expire_after_n_days` |
| Automatic container and app updates | AIO takes a backup immediately before each update |

The exact WAF expressions are in `/root/PRIVATE-NOTES.md` on pve rather than
here, same convention as the Synology wake window.

**fail2ban is deliberately not part of this design.** Behind a tunnel a jail
acting on web logs bans Cloudflare's edge and locks out everyone including
the owner, presenting as a total blackout with no obvious cause. Cloudflare's
own rate limiting runs where the client IP is a fact rather than a header.

## 5. LAN isolation

Nextcloud is the most exposed service in the homelab. Assume the container can
be compromised; without isolation that reaches pfSense, the NAS, Proxmox and
the cluster, because the LAN is flat.

[`scripts/docker-lan-isolation.sh`](scripts/docker-lan-isolation.sh) writes
`DOCKER-USER` rules that drop container traffic to RFC1918 destinations
leaving on the physical NIC, with exactly two exceptions: DNS to pfSense, and
SSH to pve for the borg backup. Container-to-container traffic stays on the
bridges and is untouched; outbound internet is unaffected.

The systemd unit is `PartOf=docker.service`, so the rules are reapplied
whenever Docker restarts and recreates its chains.

Verify:

```bash
docker exec nextcloud-aio-nextcloud timeout 6 curl -s http://<a-lan-host>/   # must fail
docker exec nextcloud-aio-nextcloud timeout 6 nc -z 10.57.57.250 22          # must succeed
docker exec nextcloud-aio-nextcloud timeout 10 curl -sI https://cloudflare.com   # must succeed
```

## 6. Backup

Nextcloud is the eighth source in the existing mesh. No new mechanism, no new
destination, no new schedule.

```
AIO borg (nightly, 23:40 UTC)
   └─ ssh://borg-nextcloud@pve/media/backups/nextcloud      encrypted, on SAS
        ├─ restic 00:10 UTC  → Oracle VPS                   encrypted, off-site
        └─ rsync weekly      → Synology                     cold, local
```

What borg captures: all AIO Docker volumes (PostgreSQL, config, apps) **and**
the datadir. Containers stop for the duration, which keeps the database and
the files consistent with each other.

What it does not capture: anything under `/mnt/nobackup`, mounted through the
External Storage app. That is the entire point of that disk.

On pve the repository is owned by a dedicated `borg-nextcloud` system account
whose key is restricted in `authorized_keys` to
`command="borg serve --restrict-to-repository …",restrict`. The key cannot run
anything else, and cannot touch any other repository.

Append-only mode was considered and rejected: it stops AIO's retention from
reclaiming space and forces a periodic manual `borg compact` forever. A
compromised Nextcloud can destroy the borg repository, but has no credential
of any kind for the restic repository on Oracle or for the Synology relay,
both of which are written *by pve*.

### Manual restore, without AIO

The one procedure worth knowing by heart. Runs anywhere borg is installed and
the repository is reachable — pve, or the Synology copy if pve is gone.

```bash
export BORG_PASSPHRASE='…'                       # password manager
borg list /media/backups/nextcloud                        # archives
borg list /media/backups/nextcloud::ARCHIVE | grep NAME   # find the file
borg extract /media/backups/nextcloud::ARCHIVE 'exact/path'
```

The file lands in the current directory. Verified 2026-08-20: a file extracted
from the archive was byte-identical to the original, and the archive contained
a file that had since been deleted from the live instance.

Restoring the whole instance is a button in the AIO interface, pointed at the
same repository, with the same passphrase.

### After losing pve entirely

`rpool` holds both the Proxmox OS and the VM disks, so a reinstall takes the
live data with it. The `media` pool is on separate disks and survives:
`zpool import media` brings `/media/backups/nextcloud` back. Rebuild the VM,
install Docker and AIO, point AIO's restore at the repository. Worst case is
one night of files.

[../REINSTALL.md](../REINSTALL.md) covers the pve side, including recreating
the `borg-nextcloud` account, which does not survive a reinstall even though
its repository does.

## 7. Operations

**Reach the admin interface** — see §3. It is needed for updates, backups and
container changes, and for nothing else day to day.

**Change optional containers** — stop containers first, change the selection,
press *Save changes*, then start. The save button is easy to miss and the
selection is silently discarded without it.

**Nextcloud majors cannot be skipped.** AIO upgrades one major at a time on
container start. Automatic updates are enabled and AIO backs up immediately
before each one, which is the safer trade for an internet-facing service.

**Bulk-import files** by copying into the datadir and running
`occ files:scan --path="<user>/files"`, not through the browser. Check first
for names Nextcloud rejects — `\ < > : " | ? *`, names ending in a dot or
space, `.htaccess` — because the scan skips them silently.

## 8. Known limits

| Limit | Effect | Live with it by |
|---|---|---|
| Cloudflare free caps request bodies at 100 MB | browser uploads above that fail with 413 | using the desktop or mobile client, which chunk |
| AIO schedules its backup in UTC, ignoring the configured timezone | in winter the backup lands an hour before the rest of the window and wakes the SAS pool separately | accepted; revisit in October |
| Cloudflare free allows one rate-limiting rule, 10 s window, 10 s block | caps request velocity rather than banning | 2FA and Nextcloud's own per-IP throttle carry the real weight |
| Geo rule blocks the owner abroad | sync clients cannot answer a challenge | disable the rule while travelling |
| Files live in ext4 inside a zvol | not readable from pve with `ls`, unlike the LXC design | §9 |

## 9. Decision record

Kept so the reasoning is not lost and the questions do not get reopened from
scratch in a year.

**Nextcloud over Seafile and OpenCloud.** Seafile's block store is unreadable
without its database — the same disease that retired HyperBackup, whose
restore needed a working DSM. OpenCloud shipped three majors between February
and May 2026 and put metadata in extended attributes, which one existing rsync
leg would have dropped without `-X`: a backup that looks correct until the day
it is needed. Nextcloud is the most boring of the three, and boring was the
requirement.

**AIO over a hand-rolled compose stack.** The original design specified an
unprivileged LXC running six containers defined by hand, with MariaDB. AIO
requires access to the Docker socket and manages its own containers, which is
fragile and unsupported inside an unprivileged LXC — hence a VM. AIO also
brings its own tested backup, restore and update paths, and serves Collabora
on the main hostname, removing the second hostname the original design needed.

**What that costs.** The original design chose Nextcloud partly because files
stay plain files on disk, readable from pve even with the application dead.
Inside a VM they are plain files on ext4 inside a zvol: still plain files, but
reachable over SSH to the VM rather than with `ls` on the host. The escape
hatch survives; it is one hop longer.

**Longhorn was never in the running for this data.** Immich and the ARR stack
live on Longhorn PVCs because their state is small. Several hundred GB of
files is a different question, and the answer did not change when the cluster
went single-node and the replica count dropped to one.
