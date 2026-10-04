# Synology DS223 — `nas`, `10.57.57.201`

DSM 7.3, two 2 TB disks in SHR (mirrored). **The one live store**: the film
library, Synology Drive, Synology Photos, and the landing spot of every
backup. The [vault](../truenas/README.md) pulls it once a day; Oracle gets it
from there.

It is on 24/7: no power schedule, no drive hibernation, *Restart
automatically when power supply issue is fixed* on, and it is a NUT client of
pve-1 (DSM → UPS → Synology UPS server `10.57.57.254`). DSM notifies when
Volume 1 has less than 20% free.

The library rotates itself: qBittorrent removes a torrent and its files after
3 days of seeding (the library keeps its hardlink), and Radarr/Sonarr import
by hardlink, never by copy.

## Layout

| Share | Holds | Recycle bin | Checksum |
|---|---|---|---|
| `media` | `Movies/`, `Shows/`, `Downloads/` — one share, or ARR hardlink imports break. **Quota 1.2 TB**, so the library can never eat the space backups need | off | on |
| `backups` | the landing: `longhorn/` (Garage's data and metadata snapshots), `pfsense/`, `oracle-vps/` — latest version only, history is the vault's | off | on |
| `homes` | Synology Drive (`<user>/Cloud`, *My Drive*) and Synology Photos (`<user>/Photos`) | default | — |
| `photo` | Synology Photos' shared space — empty; every photo is in the personal space | — | — |
| `NetBackup` | created by the rsync service and undeletable while it runs; empty, hidden, no access | — | — |

Drive (`merox/Cloud`) has four folders, one per role: `Personal/`, `Work/`
(the employer, and `Clients/<client>/`), `Lab/` (learning and side projects) and
`Shared/` (what someone else can see). Reorganised on 2026-10-04; a move is
seen by the vault as deletes, so it needs `ALLOW-DELETES` for one run.

Photos are filed by country only: `Photos/<Country>/`, with the files directly
inside, and `Photos/Diverse/` for everything without a GPS position. Done on
2026-10-02 from each file's EXIF position, offline against GeoNames; Synology
Photos' own *Places* view still groups by city.

### `drive.merox.dev`

Synology Drive in a browser on someone else's machine. Independent of the
cluster: `cloudflared` runs on the NAS itself, so the name works while
Kubernetes is down.

| | |
|---|---|
| Tunnel | `nas` (Zero Trust → Networks → Tunnels), remotely managed |
| Ingress | `drive.merox.dev` → `https://localhost:443`, origin server name and Host header `drive.merox.dev`, TLS not verified |
| DSM | Login Portal → Applications → Synology Drive → customized domain `drive.merox.dev`: DSM serves the Drive portal on that name, never the DSM desktop |
| Gate | Cloudflare WAF custom rule `drive-romania-only`: Block when the country is not RO |
| Login | the user's own DSM account, non-admin, with 2FA |

The container, started once by hand (the token is the tunnel's, kept in the
Cloudflare dashboard and never here):

```sh
sudo /usr/local/bin/docker run -d --name cloudflared --restart unless-stopped \
  --network host cloudflare/cloudflared:<version> tunnel --no-autoupdate run --token <token>
```

The Mac's Synology Drive client does not use this name: it syncs `Cloud/`
from `10.57.57.201`, at home or over Tailscale.

### NFS

NFSv4.1, one rule per client, never the subnet. `media`: the three
Kubernetes nodes (`10.57.57.80`, `.82`, `.83`). `backups`: pve-3, for
Garage's data directory (Proxmox storage `nas-backups`).

| Setting | Value | Why |
|---|---|---|
| Privilege | Read/Write | |
| Squash | **Map all users to admin** | pods write as UID 1000, which is no DSM user, so DSM's ACL refused every write under *No mapping*. Mapping everyone to `admin` is the standard way to give Kubernetes clients one owner the ACLs recognise |
| Security | sys | |
| Asynchronous | on for `media`, **off** for `backups` | a backup must be on disk when the writer is told it is |
| Mounted subfolders | on | the `crossmnt` equivalent |

Verified 2026-09-29 from all three nodes as UID 1000: write, read, and a
hardlink (link count 2) on both shares.

### Users

One user per job, none in `administrators` except `admin`:

| User | Can | Quota |
|---|---|---|
| `admin` | administration; SSH only from the MacBook's key | — |
| `merox`, `vicky` | Synology Drive, Synology Photos | — |
| `pfsense` | SFTP only, `backups` read/write | 1 GB |
| `vps` | SFTP + rsync, `backups` read/write | 10 GB |
| `vault-pull` | rsync account only, `backups` and `homes` **read-only**, from `10.57.57.250` only | — |

`pfsense` and `vps` authenticate with their backup keys, restricted to
`from="10.57.57.1"` — pfSense itself, and the VPS arriving through pfSense's
NAT. Installing a key for a non-admin user needs root once: sshd refuses a key
file the user does not own and a home that is group-writable, and DSM creates
homes `777`.

`vault-pull` uses DSM's rsync daemon (File Services → rsync), which accepts
only *rsync accounts*: "Enable rsync account" must be on, with an rsync
account for `vault-pull` carrying the same password as the DSM user.

Traps found while setting this up:

- rsync over SSH needs the full path, `vps@nas:/volume1/backups/…`;
  `/backups/…` is read as an rsync module and fails with no message.
- `rsync -a` replaces DSM's ACL with Unix modes; push with
  `--no-perms --no-owner --no-group --chmod=D755,F644`.
- Legacy `scp -O` does not work for a non-admin user; plain `scp` (SFTP) does.
