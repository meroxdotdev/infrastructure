# Architecture

What this estate is, and the rules that decide what may join it. The standing
description; how-to pages hang off it.

## The shape, and what is settled

Three Proxmox hosts, standalone, joined only through Proxmox Datacenter
Manager. Three Talos control planes, one per host, so three etcd votes sit in
three chassis. One NAS holds the data, one vault holds the offline copy, one
VPS holds the off-site copy.

| | |
|---|---|
| `pve-1` Beelink | `kubernetes-1`, iGPU passed through for transcoding |
| `pve-2` OptiPlex | `kubernetes-2` on a raw SSD with power-loss protection |
| `pve-3` OptiPlex | `kubernetes-3`, the same; PDM; Garage, Longhorn's backup target |
| `nas` Synology DS223 | the live store: media, Drive, Photos, every backup's landing |
| `vault` R730xd | TrueNAS, the offline copy; off except for its daily run |
| `vps01` Oracle | off-site services and the off-site restic repository |

Everything in the cluster is reconciled from this repository by Flux. A push is
the deploy. Nothing is configured by hand that could be configured by commit.

## The rule for backups

The instinct is "back up whatever is not in GitHub". That is close, and wrong in
a way that matters: it protects a Sonarr *deployment* and loses the quality
profiles, indexers and history inside it, because Flux can rebuild the app and
cannot rebuild what the app accumulated.

The rule is about **what is lost, and what recreating it costs**:

| Tier | Meaning | Copies | Examples here |
|---|---|---|---|
| **1 — Irreplaceable** | Gone is gone. | 3, one off-site, verified | Drive documents, photos, Joplin notes, pfSense config |
| **2 — Expensive** | Rebuildable in principle. Hours or days in practice. | 2, one off-site | ARR configs, Jellyfin state, Authentik users, n8n |
| **3 — Free** | A command or a commit reproduces it exactly. | none | Anything Flux/Ansible/Terraform emits, caches, Prometheus TSDB, Loki, the film library |

Tier 3 is where minimalism is won. **The film library is tier 3** — it is
re-acquirable, and backing it up would cost more than the disks it lives on.
Longhorn volumes that are tier 3 are backed up by nothing on purpose; the
exemption list lives in the `LonghornVolumeNeverBackedUp` alert, so adding to
it is a decision in a diff, and forgetting is not.

etcd is tier 3 and is not backed up. Three members in three chassis rebuild a
lost one from its peers; losing all three at once is a DR rebuild from this
repository plus Longhorn restores, drilled on 2026-08-29.

## How a backup reaches three places

One landing spot, several small producers. Each producer writes the one thing
it owns into the NAS's `backups/`; nothing downstream needs to know what is in
it.

```
Longhorn ── Garage (pve-3) ─┐
pfSense ────────────────────┼─→ NAS backups/ ─┐
VPS services ───────────────┘                 ├─→ vault (pull, daily) ─→ Oracle (restic)
Drive, Photos ── NAS homes/ ──────────────────┘     snapshots: 30 d + 12 m    append-only
```

A new producer inherits both further copies by writing to `backups/`. That is
the property worth protecting when changing any of this.

The NAS keeps the latest version only. History is the vault's (ZFS
snapshots) and Oracle's (restic, `--keep-within-*` retention on the VPS).

## Nothing can delete its own backups

| | Where retention runs | Who can reach it |
|---|---|---|
| NAS `backups/` | — latest only | each producer, its own folder |
| vault | TrueNAS, on the vault | nothing: it pulls, holds no inbound credential, and is off ~22 h a day |
| Oracle | on the VPS, over the filesystem | the vault, add-only — `forget` returns 403 |

A compromised producer can overwrite its own latest copy on the NAS and
nothing further: the vault pulls it as one new version beside the old ones,
and a pull that would delete more than 500 files stops before snapshotting.

Retention is expressed in `--keep-within-*` durations, never `--keep-daily N`.
Append-only stops deletion but not *insertion*: a counted policy lets a
compromised client write cheap snapshots until the real ones fall out of the
window, and the trusted host then deletes them on the attacker's behalf. The
retention job also refuses to run while any snapshot is dated in the future,
because those windows are measured from the newest snapshot rather than from now.

## What runs on the Oracle VPS

An off-site backup target and the public edge, both arguing for the smallest
surface. Nothing listens on the internet: public names arrive through the
Cloudflare tunnel, everything else over the tailnet.

| Service | Why |
|---|---|
| Authentik (server, worker, postgres, redis) | SSO |
| Joplin (server, db) | notes — tier 1 data |
| `rest-server` | the append-only backup endpoint |
| Traefik | nothing above is reachable without it |
| Pi-hole + Unbound | DNS for the tailnet |
| Guacamole | browser access to the estate without a client |
| Portainer | a view of the VPS's containers; Ansible remains their owner |
| homelab-watch | the watcher outside the estate: Telegram when home drops off the tailnet |

## What is deliberately not done

**Proxmox Backup Server.** No guest here is irreplaceable: the Talos nodes are
rebuilt from Terraform, talhelper and Flux, and their data is in Longhorn's
backups.

**Backing up the film library.** Tier 3, re-acquirable.

**A hot spare in the vault.** It would act only while the vault is on, about
ten minutes a day. A cold spare waits in a drawer instead.

**Exposing the NAS.** It holds everything. Apps reach it over Tailscale; a
browser on someone else's machine will go through Cloudflare Access with
Authentik in front, never a bare DSM login.

**Netdata in place of Prometheus.** The custom rules encode findings that a
template-driven agent cannot express — the etcd diagnosis of 2026-09-07 needed
histogram-bucket arithmetic across three days of retention.

## The rules that keep it this way

1. **A host that is backed up may not be able to delete its backups.**
2. **Retention runs where the data is trusted, never where it is produced.**
3. **An exemption is a line in git. An omission is not.** Every check names
   what it deliberately ignores, so silence means "nothing wrong" rather than
   "nothing looked".
4. **An alert that cannot fire is worse than no alert.** Neither is one that
   assumes a host is always on: the vault is watched by one healthcheck that
   expects it once a day, not by scraping.
5. **If it runs on a host, it lives in this repository.** Scripts, cron lines,
   and the secrets' *shape* (never their values).
6. **Prefer deleting a mechanism to adding one that covers its gap.**
