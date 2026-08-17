# Nextcloud — design and phased plan

> **Status: PLAN. Nothing below is deployed.** Written 2026-08-16 against the
> live state of `pve`. Every number in §1 and §3 was read off the host, not
> estimated. Supersedes the earlier Seafile and OpenCloud drafts — §10 records
> why, so the reasoning is not lost.

Replaces Filebrowser with a multi-user file service: web UI, per-user private
storage, one shared folder, public share links, in-browser Office editing, and
built-in 2FA. Immich is untouched.

Related: [spindown-setup.md](../spindown-setup.md) ·
[README.md](../README.md#nightly-schedule) · [DR.md](../../../DR.md) ·
[SECURITY-AUDIT.md](../../../SECURITY-AUDIT.md)

---

## 0. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Nextcloud**, not Seafile or OpenCloud | Criterion given: sustainable, stable, safe long-term. §10. |
| D2 | **LXC on `pve`**, Docker inside — not k8s | Longhorn replicates 3×: 400 G of files becomes 1.2 T on a pool with 1.24 T free. Arithmetic, not preference. §2. |
| D3 | **All live data on the SSD mirror.** SAS holds bulk media and backups, nothing else | The storage rule, §1. |
| D4 | **Built-in 2FA (TOTP)** — no Authentik, no external IDP | Nextcloud has it natively. Removes the dependency on the Oracle VPS for signing in to a service in your house. |
| D5 | **Own `cloudflared` in the LXC**, second tunnel | Survives a k8s outage; adds nothing to the wildcard-exposed `external` gateway (audit m6). |
| D6 | **Geo-block admin surface only**; share links open worldwide | A RO-only rule everywhere would kill links to anyone abroad. |
| D7 | **Filebrowser fully decommissioned**, and the SAS pool tidied with it | §1 and §8. |
| D8 | **Break the VPS→pve→Oracle backup loop** | Unrelated to Nextcloud, found while designing its backup. §7. |

---

## 1. Storage — the whole picture

This is the part that was not clean. The problem was never Nextcloud; it was
that there was no stated rule about what goes where, so each app decided for
itself and the result drifted.

### The rule

> **SAS holds two things: bulk media, and backups.**
> **Everything an app touches during the day lives on SSD.**

One sentence, and it explains every placement below. It also happens to be the
rule that keeps spin-down working, because both things on SAS are compatible
with sleeping disks: bulk media is read in long bursts, backups are written once
a night.

### What is on the pools today

Read from the host, 2026-08-16:

| `rpool` — SSD, 4× Intel enterprise, 2 mirrors · 448 G used, **1.24 T free** | Size |
|---|---|
| `ROOT/pve-1` — Proxmox itself | 4.48 G |
| `data/vm-800/802/804` — Talos nodes, holding every Longhorn replica | 380 G |
| `data/vm-100-disk-2` | 57.4 G |
| `data/vm-101` — Home Assistant | 3.56 G |
| `data/subvol-103` — Garage LXC rootfs | 1.03 G |
| `garage-meta` — Garage's LMDB, moved here so it stops waking the SAS pool | 9.88 M |

| `media` — SAS, 12× 600 G, 2× RAIDZ2 · 1.09 T used, **3.13 T free** | Size | Verdict |
|---|---|---|
| `library` — movies/TV | 1021 G | ✓ bulk media |
| `backups` — the nightly landing zone | 89.1 G | ✓ backups |
| `isos` — PVE templates | 2.82 G | ✓ tolerated: cold, read only when building a VM |
| `photos` — **stale** Immich copy from the Aug-2026 migration | 3.28 G | ✗ neither bulk nor backup |
| `games` — empty | 192 K | ✗ noise |
| `backups/synology-home` — **live documents**, served by Filebrowser WebDAV | 29.5 G | ✗✗ **the worst one** |

### The three things that break the rule

1. **`backups/synology-home`** — live, interactively-accessed documents sitting
   on the spin-down pool, *inside the backup tree*. It is a source pretending to
   be a backup, and every time she opened a file it woke 12 disks. **This is
   exactly what Nextcloud replaces.**
2. **`photos`** — a stale safety-net copy from when Immich moved to SSD. Its only
   reader is Filebrowser, which is going away. It also costs space in the restic
   push for data that is already covered by Immich's own backup chain.
3. **`games`** — 192 K, empty, nobody's.

So the cleanup is not extra work bolted onto this project. **Two of the three
violations are removed by the project itself**, and the third is one command.

### Target layout

```
rpool  (SSD, mirrored, enterprise)          — everything live
├── ROOT/pve-1                                Proxmox
├── data/
│   ├── vm-800 / 802 / 804                    Talos nodes → all Longhorn PVCs
│   ├── vm-101                                Home Assistant
│   ├── subvol-103                            Garage LXC
│   └── subvol-104                            Nextcloud LXC          ← new
├── garage-meta                               Garage LMDB
└── nextcloud/                                                       ← new
    ├── data                                  the files
    ├── db                                    MariaDB
    └── html                                  config + apps

media  (SAS, RAIDZ2, spin-down)             — bulk + backups only
├── library                                   movies/TV      (NFS → Jellyfin, ARR)
├── isos                                      PVE templates  (cold)
└── backups/                                  written nightly, read by restic
    ├── dump/            pfsense/             longhorn-garage/
    ├── immich-postgres/ oracle-vps/          tools/
    └── nextcloud/                                                   ← new
```

**Deleted:** `media/photos`, `media/games`, `media/backups/synology-home`.

### How each app reaches its storage

Four access paths exist. Each has exactly one reason, and no app uses more than
one for the same data:

| Path | Used by | Why this path |
|---|---|---|
| **Longhorn PVC** (on rpool, via the Talos VM disks) | Immich, Jellyfin config, ARR configs, observability | k8s apps with small live state. Longhorn gives snapshots + backup to Garage. |
| **NFS from pve** → `media/library` | Jellyfin (ro), Radarr/Sonarr/qBittorrent (rw) | The only case where a k8s app genuinely needs the bulk pool |
| **Bind-mounted ZFS dataset** | Garage LXC, **Nextcloud LXC** | Host services with large or performance-sensitive state. No layers between the app and the pool. |
| **Direct on the host** | the backup scripts | They need `zfs snapshot`, which only works host-side |

The rule for choosing: **k8s app → Longhorn. LXC → bind mount.** Bulk media is
the one exception, and it is an exception because 1 TB of movies has no business
on the SSD.

### Why Nextcloud is a bind mount and not a Longhorn PVC

| | Longhorn PVC | Bind-mounted dataset |
|---|---|---|
| 400 G of files costs | **1.2 T** (3 replicas) | 400 G |
| Fits in 1.24 T free? | **no** | yes, at 49% pool fill |
| Redundancy | 3 replicas, on top of a ZFS mirror | the ZFS mirror |
| Reading a file without the app | Longhorn healthy → Talos VM disk → zvol. Talos has no shell. | `ls /rpool/nextcloud/data/...` |

Live-verified: the `longhorn` StorageClass is `numberOfReplicas: "3"`. Setting it
to 1 for this one volume would fix the space problem but leave Longhorn adding
three layers of indirection for redundancy that `rpool`'s mirror already
provides.

The second row matters more than the first. The whole reason for choosing
Nextcloud is that files stay readable without the application — burying them in
a Longhorn volume gives that away.

### Datasets to create

```bash
zfs create -o quota=400G                    rpool/nextcloud
zfs create -o recordsize=1M                 rpool/nextcloud/data   # the files
zfs create -o recordsize=16K -o logbias=throughput rpool/nextcloud/db  # InnoDB pages
zfs create                                  rpool/nextcloud/html   # config + apps
zfs create -o mountpoint=/media/backups/nextcloud media/backups/nextcloud
```

`atime` is already `off` pool-wide on both pools, inherited by every child.
Nothing to set. Nextcloud stores its metadata in MariaDB, not in extended
attributes, so no `xattr=sa` requirement here — that trap belonged to the
OpenCloud draft and is gone.

### Capacity after the change

| | Now | After |
|---|---|---|
| `rpool` used | 448 G (26%) | ~850 G (**49%**) |
| `rpool` headroom to a 75% ceiling | — | **~450 G** for Longhorn/Immich growth |
| `media` used | 1.09 T | ~1.06 T (frees 33 G, adds ~35 G of backups) |

**The 400 G quota is the safety device, not a guess.** `rpool` also carries the
Talos VM disks — including etcd. Without a quota, a large upload could stall the
whole k8s cluster. With it, a runaway Nextcloud fails on its own and nothing else
notices. Raise it to 700 G freely; past that, redo this table first.

```bash
zfs set quota=700G rpool/nextcloud    # instant, no restart
```

---

## 2. Architecture

```
Internet
  └─ Cloudflare  (WAF: geo rules · rate limit)
       └─ tunnel "nextcloud-r730xd"
            └─ cloudflared ─┐   LXC 104  (unprivileged, nesting=1, keyctl=1)
                            ├─ nextcloud   :80    cloud.merox.dev
                            ├─ cron              (same image, /cron.sh)
                            ├─ mariadb           (internal network only)
                            ├─ redis             (internal network only)
                            └─ collabora  :9980   office.merox.dev

  bind mounts, no NFS:
    mp0  rpool/nextcloud/html → /var/www/html
    mp1  rpool/nextcloud/data → /var/www/data
    mp2  rpool/nextcloud/db   → /var/lib/mysql
```

Six containers. More than the OpenCloud draft's three — that is the price of
Nextcloud's maturity and it is the main thing you are buying with it.

Ports publish on `127.0.0.1` only. The tunnel is the sole route in; the flat LAN
cannot reach any container directly.

**Why `office.merox.dev` is a separate hostname:** you never visit it. You click
a `.docx` inside Nextcloud and the editor opens in the page. Collabora runs in
*your browser*, so your browser must fetch its JavaScript from somewhere — that
hostname. It is one extra line in the same tunnel: no extra container, no extra
tunnel, no separate DNS. Serving it from a subpath is a known source of breakage.

---

## 3. Spin-down

### Measured baseline (live, 2026-08-15)

| | |
|---|---|
| Asleep, last 5 days | 66% · 87% · 93% · 85% · 93% |
| Park commands / 24 h | 67 across 12 disks ≈ **5.6 spin-up cycles per disk per day** |
| Power | ~126 W asleep · ~156-168 W awake (**delta ~30-42 W**) |
| Jellyfin realtime monitor | confirmed `false` on both libraries |

### Effect of this project: none, and slightly positive

Nextcloud lives entirely on SSD. It touches SAS once a night, for its backup,
inside a window the disks are already awake for — **about 5 minutes a day**.

It also *removes* a daytime waker: `synology-home` is live documents on SAS
today, so every file she opens currently spins up the pool. After phase 6 that
stops.

| Day type | SAS awake | Asleep | Cycles/disk/day |
|---|---|---|---|
| No TV, no downloads | ~55 min | **96%** | 2-3 |
| Typical evening (2 h Jellyfin) | ~3 h | **87%** | 3-4 |
| Scrub night (monthly) | ~5-7 h | ~72% | 2-3 |

Nextcloud's `cron.php` runs every 5 minutes and its previews/thumbnails are
generated on upload — all of it on SSD, none of it visible to the SAS pool.

### Scheduled jobs touching SAS, and three pre-existing problems

| Time (EEST) | Job | In window? |
|---|---|---|
| **02:00** | Jellyfin *Extract Chapter Images* | ✗ **50 min early** |
| 02:50 – 03:25 | Longhorn→Garage · vzdump · pfSense · VPS rsync · Jellyfin trickplay · garage meta · Immich pg_dump · ZFS snapshot · restic push · SAS health · drift check | ✓ |
| **every 12 h** | Jellyfin *Scan Media Library* — interval trigger, **drifts** | ✗ observed 22:13 |
| weekly | Synology relay | ✓ own window |
| **monthly, 1st, 00:00** | **`zfs-scrub-monthly@media`** — hours of full-pool read | ✗ **not in your docs at all** |
| latent | `/etc/cron.d/zfsutils-linux` second-Sunday scrub | ✗ never seen firing, but unguarded |
| ad-hoc | Jellyfin playback · ARR imports to `media/library` | user/download driven |

**Found while measuring, all pre-existing and unrelated to Nextcloud:**

1. The **monthly scrub runs at 00:00 on the 1st**, outside the window. Confirmed:
   `zpool history media` → `2026-08-01.00:00:45 zpool scrub media`. The timer is
   `OnCalendar=monthly` with `AccuracySec=1d`, so its start is not even pinned.
2. A **second, latent scrub trigger** in `/etc/cron.d/zfsutils-linux` (second
   Sunday; helper executable; `org.debian:periodic-scrub` unset = auto). No scrub
   on 2026-08-09 in history, so it has not fired — but nothing stops it.
3. The **ARR stack writes to `media/library` whenever a download finishes**, at
   any hour. Not schedulable, and fine — the measured 86-93% shows it is bursty.

### Consolidated window: 02:40 – 03:30

| Change | From | To |
|---|---|---|
| Jellyfin *Extract Chapter Images* | 02:00 daily | **03:15 daily** |
| Jellyfin *Scan Media Library* | every 12 h | **daily 03:10** |
| `zfs-scrub-monthly@media.timer` | 00:00, 1st | **03:40, 1st** — extends one awake block instead of creating a second |
| `cron.d` second-Sunday scrub | latent | **disable explicitly** |
| Nextcloud backup (new) | — | **02:45**, ahead of the 03:10 restic push |

```bash
mkdir -p /etc/systemd/system/zfs-scrub-monthly@media.timer.d
cat > /etc/systemd/system/zfs-scrub-monthly@media.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-01 03:40:00
AccuracySec=1h
EOF
systemctl daemon-reload
zfs set org.debian:periodic-scrub=disable media
```

Jellyfin task times live in its PVC, not git. The nightly drift check catches a
revert because it measures the outcome, not the setting.

### Verifying — all passive, none of these touch a disk

```bash
/root/spindown-summary.sh
journalctl -t sas-spindown --since '24 hours ago' | grep -c 'standby issued'   # ÷12 = per-disk
tail -5 /var/log/spindown-drift.log
```

> ⚠️ **Two wake sources found while measuring**, worth adding to the known-wakers
> table in [spindown-setup.md](../spindown-setup.md): **`zfs get -r <prop> media`
> walks every dataset and snapshot** and woke the pool from 12/12 asleep; and the
> `smartctl` verify sweep is an SG_IO round-trip on any disk already awake.
> Measured: 23:11 `asleep=12/12 watts=134` → 23:16 `asleep=5/12 watts=156`. The
> enforcer re-sleeps within ~15 min.

> ⚠️ **Doc drift, unrelated:** the live `spindown-summary.sh` prints English
> (`now: asleep=12/12 watts=134`) while [spindown-setup.md](../spindown-setup.md)
> documents the older Romanian output. The host is ahead of the repo.

---

## 4. LXC and Docker Compose

### LXC 104

```bash
pct create 104 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nextcloud \
  --cores 4 --memory 6144 --swap 2048 \
  --rootfs local-zfs:16 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 --startup order=6 \
  --ostype debian --tags cloud-storage

pct set 104 -mp0 /rpool/nextcloud/html,mp=/var/www/html
pct set 104 -mp1 /rpool/nextcloud/data,mp=/var/www/data
pct set 104 -mp2 /rpool/nextcloud/db,mp=/var/lib/mysql
```

`nesting=1` for Docker; `keyctl=1` because MariaDB calls `keyctl` at startup and
fails without it. Reserve the DHCP lease on pfSense as you did for `10.57.57.61`.

### UID/GID mapping

Unprivileged LXC, default idmap: **container UID *n* = host UID *100000+n***.

| Host path | Owner | Container process |
|---|---|---|
| `/rpool/nextcloud/html`, `/rpool/nextcloud/data` | `133:133` → host **`100033:100033`** | `www-data` is UID 33 in the Nextcloud image |
| `/rpool/nextcloud/db` | host **`100999:100999`** | `mysql` is UID 999 in `mariadb` |

```bash
chown -R 100033:100033 /rpool/nextcloud/html /rpool/nextcloud/data
chown -R 100999:100999 /rpool/nextcloud/db
```

**Backup/restore implications:**

1. Preserve **numeric** IDs (`rsync --numeric-ids`; restic does by default).
   Without it, a restore remaps 100033 and Nextcloud cannot read its own files.
2. Restore **as root**. A non-root restore silently loses the mapping.
3. Restored files show as UID `100033` on the host. **Correct, not corruption.**
   Do not "fix" it with a `chown`.
4. Recreate LXC 104 with the **default** idmap. A custom `lxc.idmap` shifts the
   offset and the restored ownership stops matching.

### `/srv/docker/nextcloud/docker-compose.yml`

```yaml
---
services:
  db:
    image: mariadb:11.4
    container_name: nextcloud-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --log-bin=ROW
    volumes:
      - /var/lib/mysql:/var/lib/mysql
    environment:
      MARIADB_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:?}
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:?}
    networks: [nc-net]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    container_name: nextcloud-redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD:?}
    networks: [nc-net]

  app:
    image: nextcloud:34.0.3-apache
    container_name: nextcloud
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"        # loopback only — the tunnel is the sole way in
    volumes:
      - /var/www/html:/var/www/html
      - /var/www/data:/var/www/data
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:?}
      REDIS_HOST: redis
      REDIS_HOST_PASSWORD: ${REDIS_PASSWORD:?}
      NEXTCLOUD_DATA_DIR: /var/www/data
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER:?}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD:?}
      NEXTCLOUD_TRUSTED_DOMAINS: cloud.merox.dev
      # cloudflared terminates TLS — without these, Nextcloud generates http://
      # links and every redirect breaks
      OVERWRITEPROTOCOL: https
      OVERWRITECLIURL: https://cloud.merox.dev
      TRUSTED_PROXIES: 127.0.0.1
      PHP_MEMORY_LIMIT: 1G
      PHP_UPLOAD_LIMIT: 10G
    depends_on:
      db: {condition: service_healthy}
      redis: {condition: service_started}
    networks: [nc-net]

  cron:
    image: nextcloud:34.0.3-apache
    container_name: nextcloud-cron
    restart: unless-stopped
    entrypoint: /cron.sh
    volumes:
      - /var/www/html:/var/www/html
      - /var/www/data:/var/www/data
    depends_on:
      db: {condition: service_healthy}
    networks: [nc-net]

  collabora:
    image: collabora/code:24.04.13.2.1
    container_name: collabora
    restart: unless-stopped
    ports:
      - "127.0.0.1:9980:9980"
    environment:
      aliasgroup1: https://cloud\.merox\.dev
      DONT_GEN_SSL_CERT: "YES"
      extra_params: --o:ssl.enable=false --o:ssl.termination=true
      username: admin
      password: ${COLLABORA_ADMIN_PASSWORD:?}
    cap_add: [MKNOD]
    networks: [nc-net]

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN:?}
    network_mode: host             # so it can reach 127.0.0.1:8080 / :9980
    depends_on: [app]

networks:
  nc-net:
```

> **Pin exact tags and never let Renovate auto-merge a Nextcloud major.**
> Nextcloud upgrades run on container start and **cannot skip a major version** —
> 33 → 34 is fine, 32 → 34 is not. Configure Renovate to auto-merge patch and
> minor for `nextcloud`, and to open a PR you review for majors.

### Post-install `occ` steps

```bash
NC="pct exec 104 -- docker exec -u www-data nextcloud php occ"

$NC app:enable twofactor_totp                    # D4 — 2FA
$NC config:system:set default_phone_region --value="RO"
$NC config:system:set maintenance_window_start --type=integer --value=1   # 01:00 UTC
$NC db:add-missing-indices
$NC app:disable dashboard activity                # unused at 3 users

# Collabora
$NC app:install richdocuments
$NC config:app:set richdocuments wopi_url --value="https://office.merox.dev"
$NC config:app:set richdocuments public_wopi_url --value="https://office.merox.dev"

# share-link hygiene
$NC config:app:set core shareapi_enforce_links_password --value="yes"
$NC config:app:set core shareapi_default_expire_date --value="yes"
$NC config:app:set core shareapi_expire_after_n_days --value="14"
```

---

## 5. Cloudflare

### Tunnel

New tunnel `nextcloud-r730xd`, created in the Zero Trust dashboard so it issues a
token. Two hostnames:

| Hostname | Service |
|---|---|
| `cloud.merox.dev` | `http://127.0.0.1:8080` |
| `office.merox.dev` | `http://127.0.0.1:9980` |

DNS records come from the tunnel route, **not** external-dns. Nothing in
`kubernetes/apps/network/cloudflare-tunnel/` changes.

### WAF rules — order matters

**Rule 1 — "nextcloud: public share paths" · Skip → all remaining custom rules**

```
(http.host eq "cloud.merox.dev" and (
   starts_with(http.request.uri.path, "/s/")            or
   starts_with(http.request.uri.path, "/index.php/s/")  or
   starts_with(http.request.uri.path, "/public.php")    or
   starts_with(http.request.uri.path, "/core/")         or
   starts_with(http.request.uri.path, "/dist/")         or
   starts_with(http.request.uri.path, "/apps/files_sharing/")
))
```

`/s/` and `/index.php/s/` are the share-link routes, `/public.php` carries the
download, and the asset paths keep the page from rendering broken for an outside
recipient.

> Confirm these against a **live share link** in phase 2 before trusting the
> rule. Too permissive exposes more than intended; too strict breaks links
> silently, and only for the recipient — you would never see it.

**Rule 2 — "nextcloud: RO only" · Block**

```
(http.host in {"cloud.merox.dev" "office.merox.dev"} and ip.geoip.country ne "RO")
```

**Rule 3 — "nextcloud: login rate limit" · Rate limit → Block 1 h**
10 requests / 10 min per IP on `/login`.

### Geo-blocking downsides

| What breaks | Severity | Mitigation |
|---|---|---|
| You or she travel abroad | High — total lockout | **Tailscale.** 6-node tailnet with a pfSense subnet router already exists; reach the LXC on the LAN. **Test it before travelling**, not when you need it. |
| iCloud Private Relay on her iPhone | High, non-obvious | Egress is a Cloudflare IP that usually preserves country, but not always. Symptom: fails on cellular, works on Wi-Fi. |
| Roaming / foreign-routed carriers | Medium | Same symptom, same fix |
| Share links to relatives abroad | **handled** by rule 1 — its whole purpose | — |
| Collabora ↔ Nextcloud | None | Server-to-server inside the LXC |

### Cloudflare ToS — the §2.8 question from the original brief

**Section 2.8 no longer exists.** Cloudflare removed "Limitation on Serving
Non-HTML Content" from the self-serve terms in **May 2023**. It was replaced by a
narrower CDN clause in the
[Service-Specific Terms](https://www.cloudflare.com/service-specific-terms-application-services/):
serving video or "a disproportionate percentage of pictures, audio files, or
other large files" through the CDN is restricted unless the content sits on
Stream/Images/R2. Remedy is discretionary action with reasonable-effort notice.

| Traffic | Verdict |
|---|---|
| Documents, office files, PDFs, thumbnails | Fine — ordinary web app traffic |
| An occasional photo/video share link to family | Fine |
| The Jellyfin media library | **Keep it off the tunnel.** It already is — Jellyfin is on the `internal` gateway, so `media.merox.dev` is not publicly routed. Do not change that. |
| Bulk re-download of a large library over a share link | The shape that draws attention. Use Tailscale. |

Rule of thumb: if one transfer is measured in gigabytes, it belongs on Tailscale.

> ⚠️ **The limit that actually bites is the 100 MB request body cap on the free
> plan**, not the ToS. Browser uploads above that can fail with a 413.
> `PHP_UPLOAD_LIMIT: 10G` in the compose sets Nextcloud's own ceiling — Cloudflare
> is the lower one. Desktop and mobile clients chunk their uploads and are
> unaffected. Tell her once, up front: **big files go through the app, not the
> browser.**

---

## 6. Security

| # | Control | Notes |
|---|---|---|
| 1 | No WAN ports opened | Tunnel is outbound-only. pfSense untouched. |
| 2 | Container ports on `127.0.0.1` only | Not reachable from the flat LAN — relevant given audit C2/M1 |
| 3 | **2FA (TOTP) on the admin account** | `twofactor_totp`, native. Enrol immediately after first login. |
| 4 | Share links require a password, expire in 14 days | `shareapi_enforce_links_password`, §4 |
| 5 | Geo rules + login rate limit | §5 |
| 6 | Nextcloud has **no** write path to backups or Garage S3 | §7 |
| 7 | Unprivileged LXC, bind mounts only, no NFS | Adds nothing to audit finding M2 |
| 8 | Brute-force protection | Nextcloud's own, per-account. **See the real-IP warning below.** |
| 9 | Secrets in `.env`, mode `0600`, values in Ansible Vault | Same pattern as `/srv/docker/oracle-cloud/.env` |
| 10 | Renovate on all four images, **no auto-merge for Nextcloud majors** | §4 |

### The real-IP trap — read before enabling anything IP-based

Behind a tunnel, **every request arrives from a Cloudflare IP**. Nextcloud's
built-in brute-force protection is per-account and IP-aware; with
`TRUSTED_PROXIES: 127.0.0.1` it will see cloudflared's address for everyone.

That is *safe* here — worst case the throttle is coarse. But it is why **fail2ban
is deliberately not in this design**: a jail acting on those logs bans
Cloudflare's edge and locks out everyone including you, presenting as a total
blackout with no obvious cause. Cloudflare's own rate limiting (rule 3) runs at
the edge where the client IP is a fact rather than a header to be trusted.

If you ever want per-IP accuracy inside Nextcloud, configure real-IP restoration
**first** and verify the logs show genuine client addresses before acting on them.

### Verify Collabora is not open

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://office.merox.dev/browser/dist/admin/admin.html
# must not be reachable without the credentials from the compose
```

---

## 7. Backup and restore

### Why Nextcloud must not reach the backups

**Written down so it does not get "simplified" later:** Nextcloud is the most
exposed thing in this design — a public web application that accepts uploads from
the internet. Assume it can be compromised.

If it could write to `/media/backups` or to Garage S3, a compromise of Nextcloud
is a compromise of the backups: encrypt the files, encrypt the backups, done.
Backups exist for the case where the live service has been destroyed, so **the
live service must not be able to destroy them**.

Therefore the backup job runs **on `pve`**, not in the LXC and not in a
container. It reads the datasets host-side and pushes outward. Nothing under
`/media/backups` and no Garage credential is ever mounted into LXC 104.

Same shape as the Garage LXC: the container holds data, the host moves it.

### The nightly job

Nextcloud's metadata is in MariaDB, and the DB must match the files. Maintenance
mode makes that trivial — at three users a 10-second pause at 02:45 is invisible,
and it beats reasoning about write ordering.

`/root/scripts/nextcloud-backup.sh`, cron `45 2 * * *`:

```bash
#!/bin/bash
# Explicit PATH: user crontabs get only /usr/bin:/bin.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Nextcloud nightly backup. Runs on pve, NOT in the LXC — Nextcloud must never
# hold a writable path to its own backups (see DESIGN.md §7).
#
# Maintenance mode is on for the snapshot only (~10s). It removes any question
# of the DB dump and the files disagreeing, which is the one way a restore of
# this shape goes silently wrong.
set -euo pipefail

DEST=/media/backups/nextcloud
STAMP=$(date +%F)
OCC="pct exec 104 -- docker exec -u www-data nextcloud php occ"
mkdir -p "$DEST"

cleanup() { $OCC maintenance:mode --off >/dev/null 2>&1 || true; }
trap cleanup EXIT

$OCC maintenance:mode --on

pct exec 104 -- docker exec nextcloud-db \
  mariadb-dump -unextcloud -p"$(cat /root/.nextcloud-db-password)" \
    --single-transaction --default-character-set=utf8mb4 nextcloud \
  | gzip -9 > "$DEST/nextcloud-db-$STAMP.sql.gz"

for ds in data html; do
  zfs destroy -r "rpool/nextcloud/$ds@backup" 2>/dev/null || true
  zfs snapshot "rpool/nextcloud/$ds@backup"
done

$OCC maintenance:mode --off
trap - EXIT

for ds in data html; do
  rsync -a --delete --numeric-ids \
    "/rpool/nextcloud/$ds/.zfs/snapshot/backup/" "$DEST/$ds/"
done

# Prune DB dumps by name, never `find -mtime` — rsync preserves source mtimes
# elsewhere in this tree and that has bitten before.
find "$DEST" -maxdepth 1 -name 'nextcloud-db-*.sql.gz' -mtime +30 -delete

curl -fsS -m 10 --retry 3 "https://hc-ping.com/<uuid>" > /dev/null
```

The 03:10 restic push picks this up with no change to `restic-push-oracle.sh` —
its scope is already everything under `/media/backups/`.

**Add `nextcloud` to the category list in `weekly-push-to-synology.sh`.** Per
[README.md](../README.md#downstream-legs) those legs enumerate subdirectories
explicitly and **do not pick up a new one automatically** — checked before, not
assumed.

### D8 — break the VPS backup loop

Found while designing the above. Unrelated to Nextcloud, worth fixing in the same
pass.

**The loop:** the VPS pushes its state down to `/media/backups/oracle-vps` at
03:00. At 03:10 `restic-push-oracle.sh` includes that same directory in the push
**back up to Oracle** — and the repository is `sftp:oracle-vps-restic:/data`,
i.e. **the same VPS the data came from**.

So VPS data round-trips, and its "offsite" copy lands on its own source machine.
Lose the Oracle account — free tier, idle reclamation is routine — and you lose
source and backup together.

**Fix, one line:** drop `/media/backups/oracle-vps` from the restic push. For VPS
data `pve` already *is* the offsite copy — different building, different country.
A third hop back into Oracle adds nothing.

```bash
restic backup /media/backups/immich-postgres \
  /media/backups/pfsense /media/backups/longhorn-garage \
  /media/backups/nextcloud /media/backups/tools /root --tag nightly
```

Note `synology-home` and `/media/photos` also leave that line — both datasets are
deleted in §8. `nextcloud` takes their place.

**The larger issue that fix does not solve.** The restic repository for the
*entire* homelab lives on the Oracle VPS. Losing that account costs a whole
backup tier for everything, not just VPS data. What remains is `pve` and the
Synology — **both in the same building** — so a total loss after an Oracle
reclaim leaves nothing.

[README.md](../README.md#backup--off-site-strategy) records the VPS failure as
*"loses ≤1 night of its own service backups"*. That understates it.

Out of scope here, but worth a decision: a second restic repo at a different
provider (Hetzner Storage Box ~€3.50/mo for 1 TB, or Backblaze B2) restores a
genuine third domain. Everything else in your backup design is 3-2-1; this leg is
not.

### Restore

```bash
# 1. Datasets + LXC with the DEFAULT idmap (§4)
zfs create -o quota=400G rpool/nextcloud
zfs create -o recordsize=1M  rpool/nextcloud/data
zfs create -o recordsize=16K rpool/nextcloud/db
zfs create rpool/nextcloud/html
# ... pct create per §4, leave it stopped

# 2. Files back, as root, numeric IDs preserved
rsync -a --numeric-ids /media/backups/nextcloud/data/ /rpool/nextcloud/data/
rsync -a --numeric-ids /media/backups/nextcloud/html/ /rpool/nextcloud/html/
chown -R 100033:100033 /rpool/nextcloud/data /rpool/nextcloud/html

# 3. DB only, load the dump
pct start 104
pct exec 104 -- docker compose -f /srv/docker/nextcloud/docker-compose.yml up -d db
zcat /media/backups/nextcloud/nextcloud-db-<date>.sql.gz | \
  pct exec 104 -- docker exec -i nextcloud-db mariadb -unextcloud -p<pw> nextcloud

# 4. Everything else
pct exec 104 -- docker compose -f /srv/docker/nextcloud/docker-compose.yml up -d
pct exec 104 -- docker exec -u www-data nextcloud php occ maintenance:mode --off
pct exec 104 -- docker exec -u www-data nextcloud php occ files:scan --all

# 5. Verify: log in, open a file, confirm an existing share link still resolves
```

**The escape hatch, and the reason Nextcloud was chosen:** if the database is
ever unrecoverable, the files are still plain files on disk —
`/rpool/nextcloud/data/<user>/files/...`. You lose shares, versions and tags, but
not the documents. `occ files:scan --all` rebuilds the rest from what is on disk.
No other candidate offered that.

### Testing it

1. **Once, before trusting it:** full restore into a throwaway LXC on `px-0` —
   already the DR-test target, already mounts `/media/backups` as PVE storage
   `r730xd-backups`. Step 5 is the one that matters; a file count proves nothing.
2. **Monthly, automated:** extend `restic-restore-drill.sh` to include
   `nextcloud-db-*.sql.gz` alongside the pfsense and immich-postgres files it
   already hash-compares.
3. **Quarterly, manual:** repeat step 1.

> ⚠️ Same caveat as the existing drill: it runs **on `pve`**, where the password
> file is present. It proves the data is good. It cannot prove you can still open
> the repo without `pve`.

---

## 8. Migration from Filebrowser, and the SAS cleanup

Full decommission, as chosen. **Consequence, once more:** after phase 5 there is
no browser view of `media/library`, `media/backups` or `media/isos`. Those become
SSH/NFS only.

| Phase | Work | Done when | Rollback |
|---|---|---|---|
| **1. Prepare** | Datasets, LXC 104, compose, first boot **on the LAN only, no tunnel** (`http://10.57.57.x:8080`). Enable 2FA. Apply the D8 restic change and the §3 scrub/Jellyfin changes. | Admin logs in, 2FA enrolled, a test file survives a restart | `pct destroy 104`, `zfs destroy -r rpool/nextcloud` |
| **2. Expose** | Tunnel, both hostnames, WAF rules. **Confirm the real share-link paths** against a live link, then finalise rule 1. Test her PWA and a share link from cellular data. Test Tailscale as the abroad path. | She adds it to her home screen and signs in once | Delete the tunnel. Filebrowser still live. |
| **3. Migrate data** | Copy the 29.5 GB from `media/backups/synology-home`. **Upload through the desktop client or the web UI**, not by dropping files into `data/` — Nextcloud must write its own DB rows. (If you ever do copy in directly, `occ files:scan` afterwards.) | File count and spot checks match | Delete and re-copy. Source untouched. |
| **4. Parallel run** | Both live. She uses Nextcloud only. `synology-home` stays read-only and untouched. **Minimum two weeks**, plus one successful restore drill. | Two weeks, no complaints, restore proven | Point her back at Filebrowser. Zero data loss. |
| **5. Decommission + tidy** | `git rm -r kubernetes/apps/default/filebrowser`, drop it from `kustomization.yaml`, Flux prunes it. Then remove the `/media/photos` NFS export, and delete `media/photos` and `media/games`. | Pod gone, exports removed, `exportfs -ra` | `git revert` for the manifests; `media/photos` is recoverable from restic until the retention window closes |
| **6. Reclaim** | After a **third** clean restore drill: delete `media/backups/synology-home`. | ~33 GB freed, SAS pool now matches the rule in §1 | restic / Synology |

Notes:

- **Do not delete `synology-home` before phase 6.** Between 3 and 6 it is your
  rollback, and it is a live source in the backup tree — not a copy of the
  Nextcloud data, the original.
- **Before deleting `media/photos` in phase 5**, confirm Immich's own restore
  path works ([docs/immich-post-restore.md](../../../docs/immich-post-restore.md)).
  It is a stale safety net from the Aug-2026 migration; once Immich's chain is
  proven it is dead weight in every backup leg.
- Removing the `/media/photos` export is also a small security win: audit M2
  recommends dropping `no_root_squash` where it is not required, and this export
  stops being required at all.
- Phases 1-2 fit in one evening. Phase 4 is waiting. Resist compressing it.

---

## 9. What could go wrong — top 5

| # | Failure | How it presents | How you notice | Prevention / fix |
|---|---|---|---|---|
| 1 | **`rpool` fills** | Nextcloud writes fail *and* Talos VM disks stall — etcd is on the same pool. A cluster-wide incident caused by an upload. | `zfs list rpool`; alert at 320 G | The 400 G quota. It turns a cluster outage into a Nextcloud-only error. Do not skip it, do not raise it without redoing the table in §1. |
| 2 | **A skipped Nextcloud major** | Container restarts into a broken upgrade; the web UI shows an upgrade error and stays down | Immediately, and loudly | Never let Renovate auto-merge a major. Upgrade one major at a time, snapshot the datasets first. §4. |
| 3 | **Backup taken without maintenance mode** | DB and files disagree; restore has files the DB does not know about, or rows pointing at missing files | Only a real restore drill catches it | The `trap`-protected maintenance window in §7. If you ever hand-roll a backup, use the same order. |
| 4 | **Geo rule locks you out while travelling** | Total 403 on everything, from a hotel, at the worst moment | Immediate | Tailscale, **tested in phase 2**, not the first time you need it |
| 5 | **Cloudflare 100 MB body limit** | Browser upload of a large file dies around 100 MB, 413, no useful message | Her, reporting "it does not work" | Desktop/mobile client, or Tailscale. Tell her once, up front. |

Honourable mention: **a Jellyfin library re-add silently re-enables the realtime
monitor** and quietly halves spin-down. Already covered — the nightly drift check
measures the outcome, not the setting.

---

## 10. Decision record — why Nextcloud, after two other drafts

Kept so the reasoning is not lost and the question does not get reopened from
scratch in a year.

| | Seafile CE | OpenCloud | **Nextcloud** |
|---|---|---|---|
| Containers | 5 | 3 | **6** |
| Files readable without the app | ✗ content-addressed blocks | ✓ | **✓** |
| Metadata | MariaDB | xattrs — one existing rsync leg would have silently dropped them | **MariaDB dump, explicit and verifiable** |
| 2FA built in | ✓ | ✗ needs an external IDP | **✓ TOTP + WebAuthn** |
| Major releases | slow | **~every 7 weeks** | ~3/year, ~1 year support each |
| Project age | 2012 | org 19 months, code ~6 years | **2016, 36k stars, 3 branches patched same-day** |

**Seafile was dropped** because its block store is unreadable without MariaDB —
the same disease that made you retire HyperBackup, whose restore needed a working
DSM.

**OpenCloud was dropped** on the stated criterion of *sustainable, stable, safe
long-term*. Its code and team are solid — the top contributors are the engineers
who built ownCloud Infinite Scale, and it is backed by the Heinlein Group. But it
shipped v5 → v6 → v7 between February and May 2026, a major every ~7 weeks. Fewer
containers is not the same as less to keep up with, and an early assessment here
conflated the two. It also put metadata in extended attributes, which
`weekly-push-to-synology.sh` would have dropped without `-X` — a backup that
looks correct until the day it is needed.

**Nextcloud costs** six containers instead of three, one major upgrade a year
forever, and a heavier web UI. It buys the largest install base of the three, a
dedicated security team, native 2FA, a restore path thousands of people have
already walked, and files that stay plain files on disk.

At three users and 29.5 GB, none of Nextcloud's ecosystem advantages get used —
and none of them are why it was chosen. It was chosen because it is the most
boring, and boring was the requirement.
