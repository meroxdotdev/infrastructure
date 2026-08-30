# radarr-public

Fills the public Jellyfin library at `studio.merox.dev`, capped at 1080p.
Separate from `radarr` on purpose — see
[docs/jellyfin-public-exposure.md](../../../../docs/jellyfin-public-exposure.md).

## Why a second instance

One Radarr cannot hold the same film twice, and the two libraries overlap by
design: the same title exists as 4K on the SAS array and as 1080p on the SSD.

It also makes the cap structural. The quality profile here has nothing above
1080p enabled, so a 4K remux cannot land on the SSD pool by mistake — the same
argument the public Jellyfin makes about storage rather than policy.

## No overlap with the personal stack

| | |
|---|---|
| Mounts | `/public/library` only. No mount of `/media/library` exists in this pod, so the 4K library is unreachable, not merely unused |
| Download path | `/public/downloads`, on the SSD pool. Fetching never spins up the twelve SAS disks |
| qbittorrent | shared instance, own `public` category and save path |
| Prowlarr | shared indexers, which carry no library state |
| Jellyfin | `jellyfin-public`, its own library and accounts |

Same mount path (`/public`) in qbittorrent and here, on one filesystem, so
imports are hardlinks: a seeding torrent costs no second copy of a 6-8 GB file.

## Config, which lives in the PVC and not in git

The PVC is outside the backup set. Rebuild in a few minutes:

| Setting | Value |
|---|---|
| Root folder | `/public/Movies` |
| Quality profile | `1080p max` — allow `Bluray-1080p`, `WEBDL-1080p`, `WEBRip-1080p`, `HDTV-1080p`, and the 720p tiers as fallback. **Nothing above 1080p enabled** |
| Quality profile → upgrades | Until `Bluray-1080p` |
| Download client | qbittorrent, category `public` |
| Indexers | added by Prowlarr, as a second app there |
| Media management | rename on, hardlinks on |

### qBittorrent settings this depends on

Global, in qBittorrent's own config (PVC, not git). Both were wrong on the
first download and sent a public film to the SAS array:

| Setting | Value | Why |
|---|---|---|
| `use_category_paths_in_manual_mode` | **true** | Without it qBittorrent ignores a category's save path entirely and uses the global default. The `public` category's path is the only thing keeping these downloads off the SAS array |
| `temp_path_enabled` | **false** | The temp path is global and lived on the SAS array, so an in-progress public download wrote there and only moved to SSD on completion. There is no per-category incomplete path in this version — the WebAPI accepts `downloadPath` on `editCategory` and silently ignores it |

Category `public` → save path `/public/downloads`. The other categories have an
empty save path, so they still fall back to the global default and nothing about
the personal stack changed.

Size limits per quality matter more than usual: the pool has a 400 G quota
shared with nothing else, and ~50 titles at 6-8 GB is what it was sized for.

## Ops

```sh
kubectl -n default logs deploy/radarr-public -f
df -h /public/library                      # on pve: quota is 400G
ls /public/library/downloads               # in-flight
```
