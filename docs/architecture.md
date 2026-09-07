# Architecture

What this estate is, and the rules that decide what may join it. Distinct from
[`plan-2026-09.md`](plan-2026-09.md), which is a time-bound list of work; this
is the standing description that outlives it.

## The shape, and what is settled

Three Proxmox hosts, standalone, joined only through Proxmox Datacenter Manager.
Three Talos control planes, one per host, so three etcd votes sit in three
chassis. That is deliberate and not up for revisiting:

| | |
|---|---|
| `pve-1` Beelink | `kubernetes-1`, iGPU passed through for transcoding |
| `pve-2` R730xd | `kubernetes-2`, the disks, the backup hub |
| `pve-3` OptiPlex | `kubernetes-3` on a raw SSD with power-loss protection |

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
| **1 — Irreplaceable** | Gone is gone. No amount of time brings it back. | 3, one off-site, verified | Immich library, Nextcloud files, `/media/photos`, Joplin notes, pfSense config |
| **2 — Expensive** | Rebuildable in principle. Hours or days in practice. | 2, one off-site | ARR configs, Jellyfin state, Authentik users, Immich database, Nextcloud VM image |
| **3 — Free** | A command or a commit reproduces it exactly. | none | Anything Flux/Ansible/Terraform emits, caches, Prometheus TSDB, Loki, the film library |

Tier 3 is where minimalism is won. **The 1.1 TB film library is tier 3** — it is
re-acquirable, and backing it up would cost more than the array it lives on.
Eleven of the twenty-three Longhorn volumes are tier 3 and are backed up by
nothing on purpose; the exemption list lives in the `LonghornVolumeNeverBackedUp`
alert so that adding to it is a decision in a diff, and forgetting is not.

etcd is the one deliberate exception. Strictly it is tier 3 — Flux rebuilds the
cluster from this repository, and the secrets are here under SOPS. It is
snapshotted anyway because it turns a 71-minute rebuild into minutes, which
makes it an RTO optimisation rather than a backup.

## How a backup reaches three places

One funnel, several small producers. Each producer writes one thing it owns into
`/media/backups` on `pve-2`; everything downstream moves that directory and does
not need to know what is in it.

```
Longhorn volumes ─┐
etcd snapshots    │
Immich database   ├─→ /media/backups ─┬─→ restic ──→ Oracle  (append-only)
Nextcloud data    │   on pve-2        │
pfSense config    │                   └─→ Synology (pull, weekly)
Nextcloud VM dump ┘
```

A new producer inherits both off-site copies by writing to that directory. That
is the property worth protecting when changing any of this.

`dump/` is the one exclusion, and it is deliberate: a VM image is ~8-10 GiB, the
Oracle repository has ~10 GiB of headroom, and a machine image is worth
restoring over the LAN rather than from Frankfurt. It keeps the array and the
NAS.

## Nothing can delete its own backups

Fixed 2026-09-07. The property is asymmetry, and it is the reason two of the
mechanisms below cannot be collapsed into one:

| | Where retention runs | What `pve-2` can do |
|---|---|---|
| Oracle | on the VPS, over the filesystem | add only — `forget` returns 403 |
| Synology | on the NAS, after it pulls | nothing; it holds no credential for the NAS |

Retention is expressed in `--keep-within-*` durations, never `--keep-daily N`.
Append-only stops deletion but not *insertion*: a counted policy lets a
compromised client write cheap snapshots until the real ones fall out of the
window, and the trusted host then deletes them on the attacker's behalf. The
retention job also refuses to run while any snapshot is dated in the future,
because those windows are measured from the newest snapshot rather than from now.

## What runs on the Oracle VPS

It is a public edge and an off-site backup target. Both roles argue for the
smallest possible surface.

| Keep | Why |
|---|---|
| Authentik (server, worker, postgres, redis) | SSO for the public routes |
| Joplin (server, db) | notes — tier 1 data |
| `rest-server` | the append-only backup endpoint |
| Traefik | nothing above is reachable without it |
| Pi-hole + Unbound | DNS for the tailnet |

| Remove | Why |
|---|---|
| **Portainer EE** | Ansible owns these containers; a UI editing them beside Ansible only produces drift. Its cluster agent also held a `cluster-admin` binding. |
| **Guacamole** | Tailscale plus SSH/RDP is how these machines are actually reached. Retiring it also removes one of Authentik's two real consumers. |

| Missing | Why it matters |
|---|---|
| **A watcher outside the cluster** | Nothing observes the estate from a machine that is not part of it. `kube-state-metrics` has already gone down together with the host it was monitoring. |

## What is deliberately not done

**Proxmox Backup Server.** Correct for an estate with many irreplaceable guests.
Here there is exactly one — the Nextcloud VM — because the Talos nodes are
rebuilt from Terraform, talhelper and Flux, and everything else is scratch. One
weekly `vzdump` into the existing funnel covers it. A backup server would be a
system added to solve a problem of one.

**Backing up the film library.** Tier 3, 1.1 TB, re-acquirable.

**Rebuilding `pve-2` on ext4 + LVM-thin.** It buys removing a zvol from under
VM 811, on disks at 0% wear after 9,000 hours, and costs rebuilding the NFS
server, the backup hub and the Nextcloud VM. Largest-looking item available;
worst ratio in it.

**Netdata in place of Prometheus.** The stack costs 2 GB and 526m CPU, and the
custom rules encode findings that a template-driven agent cannot express. The
etcd diagnosis of 2026-09-07 needed histogram-bucket arithmetic across three
days of retention; that is not a dashboard feature.

## The rules that keep it this way

1. **A host that is backed up may not be able to delete its backups.**
2. **Retention runs where the data is trusted, never where it is produced.**
3. **An exemption is a line in git. An omission is not.** Every check names
   what it deliberately ignores, so silence means "nothing wrong" rather than
   "nothing looked".
4. **An alert that cannot fire is worse than no alert.** Two in this repository
   were calibrated past the point of ever firing; both read as coverage.
5. **If it runs on a host, it lives in this repository.** Four scripts on
   `pve-2` — including the one keeping etcd stable — existed nowhere else until
   2026-09-07.
6. **Prefer deleting a mechanism to adding one that covers its gap.**
