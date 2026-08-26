# Jellyfin public exposure — measurements, decisions & build log

Forensic record of how `studio.merox.dev`/`media.merox.dev` public exposure
was designed and built. For current architecture, settings, and how to
operate/rebuild it, see
[jellyfin-public-exposure.md](jellyfin-public-exposure.md).

## Measurements

All figures measured 2026-08-23, home (Orange RO, DHCP) to the VPS.

| Path | Congestion control | Throughput |
|---|---|---|
| home → Phoenix, 200 MB raw | cubic | 30 Mbps |
| home → Phoenix, 200 MB raw | **bbr** | **103 Mbps** |
| Phoenix → home, 100 MB raw | bbr | 150 Mbps |
| home upload → Cloudflare (local PoP) | — | 431 Mbps |
| home → Frankfurt, 100 MB | — | 293 Mbps |
| home → Fremont CA, 100 MB | — | 66 Mbps |
| RTT home ↔ Phoenix | — | 158-165 ms |

103 Mbps supports one UHD remux, or roughly five concurrent 4K x265/WEB-DL
streams, or any realistic number of 1080p streams.

> **Measurement trap:** the first attempts used a 485 KB Jellyfin web asset
> and consistently reported ~21 Mbps regardless of tuning. At 165 ms RTT an
> object that small is latency-bound — the method itself caps out near 23
> Mbps. Only continuous multi-hundred-megabyte transfers give a meaningful
> number.

The GPU time-slicing decision was also measured, not assumed: the original
design gave the public instance no GPU on the theory that re-encoded content
would direct-play. Under a real stream, seven of ten films exceeded the
client bitrate cap and transcoded anyway; one software transcode took 7.2 of
the node's 10 cores. With time-slicing the single Quadro is advertised as
two schedulable units, and four concurrent streams across both instances sat
at 71% node CPU. The binding limit becomes the NVENC engine (~100% at
roughly three simultaneous transcodes) — VRAM and CPU still had headroom.

## Decisions

### Cloudflare Tunnel — rejected

The old §2.8 is gone from the main terms, but the restriction moved to the
[Service-Specific Terms — Application Services](https://www.cloudflare.com/service-specific-terms-application-services/)
(updated 2026-06-02):

> "Unless you are an Enterprise customer, Cloudflare offers specific Paid
> Services (e.g., the Developer Platform, Images, and Stream) that you must
> use in order to serve video and other large files via the CDN."

Tunnel traffic transits the CDN. A paid plan does not fix it — Pro and
Business are not listed; only Enterprise, or hosting the library in
Cloudflare Stream. The blast radius matters more than the probability: the
same account holds DNS for `merox.dev`, the blog on Pages, and the tunnel
for everything else.

Consequence: the `media` record must stay **grey-cloud**. `external-dns`
runs with `--cloudflare-proxied` globally, but it only watches
`--gateway-name=external` and the Jellyfin route lives on the `internal`
gateway, so it will never adopt and re-proxy the record.

### A second Oracle instance — rejected

The VPS is 2 OCPU / 11 GB, which is exactly the current Always Free A1
allocation (halved from 4/24 on 2026-06-15). There is no spare quota, and
Oracle warns that "if an existing resource is terminated, it may not be
possible to recreate resources above the updated Always Free limit." Home
region is `us-phoenix-1` and
[cannot be changed](https://docs.oracle.com/en-us/iaas/Content/Identity/regions/managingregions.htm).
A second free account would violate Oracle's one-account-per-person term.

### A paid EU edge — deferred

Netcup VPS piko (Nuremberg, 25 ms, ~€1.84/month) or Hetzner (Helsinki,
12 ms) would raise the ceiling from 103 Mbps to line rate and cut ~150 ms of
latency. Worth revisiting only if UHD remuxes or start/seek latency become
a problem. Every hosting provider's AUP contains a clause equivalent to
netcup's, prohibiting "material protected by copyright for whose
dissemination the user is not authorised" — serving from home avoids any
provider AUP.

### Direct port-forward from home — rejected

Free and fastest, and pfBlockerNG is already installed, but it puts the
home IP in public DNS permanently — passive-DNS databases keep the history
even after a later migration. Inconsistent with running qBittorrent behind
Gluetun/Surfshark specifically to keep that address private.

### Tailscale for viewers — rejected

Free and fastest of all (direct RO↔RO), but requires an app on every device
and
[node sharing does not carry subnet routes](https://tailscale.com/kb/1084/sharing),
so it would need either tailnet users with ACLs or Tailscale running inside
the cluster. Remains the right answer for personal devices.

### A dedicated WireGuard tunnel — not needed

Considered to bypass pfSense's userspace `wireguard-go`. Measurement showed
pfSense at 96% idle with `tailscaled` at 4.9% CPU and zero retransmits
during transfers, so it was never the bottleneck. Dropping this removes an
Ansible role, a key to manage, a step in the R730xd runbook, and a DR
dependency.

## Build log

### Phase 1 — BBR on the cluster node

`talos/patches/global/machine-sysctls.yaml` gains one line next to the
existing `net.core.*` tuning: `net.ipv4.tcp_congestion_control: "bbr"`.
Applied with `--mode=no-reboot` after a dry-run. Verified: node reports
`bbr`, Jellyfin pod reports `bbr` after a rollout restart.

Pods inherit this at netns creation, so running workloads needed a restart:

```bash
kubectl rollout restart deployment/jellyfin -n default
kubectl exec -n default deploy/jellyfin -- cat /proc/sys/net/ipv4/tcp_congestion_control
```

BBR does not need the `fq` qdisc — TCP has had internal pacing since kernel
4.13. Below 1 ms RTT BBR and CUBIC behave identically, so LAN traffic
(Longhorn, etcd, NFS, Prometheus) is unaffected. The Cloudflare tunnel is
QUIC over UDP and Tailscale is WireGuard over UDP, so neither is touched.

> Tried and reverted: `net.ipv4.tcp_slow_start_after_idle: "0"`. Sound in
> theory for bursty HLS segments over a 165 ms path, but unlike
> `tcp_congestion_control` it is not inherited from the host — every new
> netns starts at `1`. Making it reach pods needs `allowedUnsafeSysctls` on
> the kubelet plus a pod `securityContext`, not worth it for an unmeasured
> gain.

### Phase 2 — Traefik: two doors

| Entrypoint | Container port | Published | Who listens |
|---|---|---|---|
| `public` | `:8443` | host `:443` → Oracle NSG | **only** `jellyfin`, `jellyfin-auth` |
| `https` | `:443` | no | everything else — reached over the docker bridge |
| `http` | `:80` | host `:80` | redirect to `public` only |

The tunnel previously reached Traefik at `https://localhost:443`, i.e.
through the published host port. Repointing it at the bridge address
`172.25.10.2:443` freed the host's `:443` for Jellyfin and decoupled the
tunnel from host port mapping entirely.

A Traefik router with no `entryPoints` binds to **all** of them
([docs](https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/)).
The repo contained 9 explicit `entrypoints=https` labels (Authentik,
Homepage ×2, Portainer, Pi-hole, Joplin, Garage, Traefik ×2) plus Guacamole
in `config.yml.j2`. Moving each one to a new entrypoint would mean a single
miss exposes Authentik publicly. Instead **the port was renamed, not the
routers**: `https` keeps its name and moves to `:8443`. All nine labels
stayed untouched and became private. `public` is a new entrypoint that only
Jellyfin binds to explicitly. `asDefault: true` on `https` inverts the
failure mode — anything forgotten stays hidden.

Files changed: `traefik.yml.j2` (entrypoints), `docker-compose.yml.j2`
(`443:443` → `443:8443`), `config.yml.j2` (routers, service, rate limit),
`vars.yml` (`jellyfin_domain`, `jellyfin_backend_ip`, `jellyfin_backend_port`),
`site.yml` (geoblock role ordering).

VPS tunnel topology as found during this work:

```
inside.merox.dev  ->  https://localhost:443       only hostname via Traefik
sso.merox.dev     ->  http://172.25.10.72:9000    Authentik directly
rmt.merox.dev     ->  http://172.25.10.72:9000    Authentik outpost proxy
*                 ->  404
```

Two consequences: Traefik on the VPS serves exactly one public hostname, so
the `guacamole` router in `config.yml.j2` is dead configuration — `rmt` is
handled by Authentik's embedded outpost. And `cloudflared` runs as a
**systemd unit**, not the docker container `cloudflared_setup` deploys;
that role's first tasks stop and disable the systemd service, so a full
`make setup` would migrate it as a side effect — apply with
`--tags traefik,geoblock` instead and treat that migration as its own
deliberate change.

Login rate limit: 5/min per source IP, burst 3, on
`/Users/AuthenticateByName` only, with `ipStrategy: {}` so it uses the real
connection address rather than a forgeable header.

### Phase 3 — Geoblock

Role [`vps/roles/geoblock_ro/`](../vps/roles/geoblock_ro/README.md): an
ipset enforced as a `DROP` in `DOCKER-USER`, refreshed daily and at every
boot.

**Allow by operator, not by country.** The first version used an ipdeny
country list and leaked: a phone on Surfshark reached the service from
several countries. Every exit that got through was a hosting network
registered in Romania and therefore inside the country list — M247
(AS9009) alone announces ~4250 prefixes against ~610 for every Romanian
consumer ISP combined. The allow-list is now the prefixes announced by
AS8708, AS9050, AS8953, AS12302 and AS6910, fetched from RIPEstat.

Not a Traefik plugin: they all read `X-Forwarded-For` by default, which a
client fully controls on a directly exposed entrypoint. ipset also drops
before the TLS handshake and does not couple to the floating `traefik:latest`
image.

**The rule took three attempts**, two of which looked right and silently
were not — see the role README. Short version: docker DNATs before
`FORWARD`, so `--dport 443` matched nothing; `--ctorigdstport 443`
additionally matched container-initiated outbound HTTPS and dropped its
replies; the working form matches the container address and its
container-side port.

Verified while the port was open: M247, HostRoyale, Datacamp and Googlebot
all dropped; Orange and DIGI allowed; 343 packets dropped within the first
hour.

### Phase 3b — Egress circuit breaker

The tenancy is Pay As You Go, so egress past Oracle's 10 TB/month free
allowance is billed at roughly $0.0085/GB. An OCI budget only alerts.

Role [`vps/roles/egress_guard/`](../vps/roles/egress_guard/README.md): an
hourly timer reads the monthly TX counter on the billed uplink and drops
the public entrypoint above the configured ceiling. The thresholds live in
the Ansible vault, not here — stating the exact cut-off in a public repo
tells anyone how much traffic to push to take the service down.

This is a guarantee rather than a hope. The home uplink measures ~430
Mbps, so at most ~0.19 TB can move between two hourly checks — the worst
case stays comfortably inside the 10 TB allowance and no egress bill is
reachable. Baseline before Jellyfin was 16 GB/month; three concurrent 10
Mbps streams four hours a day would add ~1.6 TB.

It fails open: an unreadable `vnstat` leaves iptables untouched and retries
next hour, because a monitoring hiccup must not take the service down.
SSH, the Cloudflare tunnel and Tailscale are never touched — only the
public port.

### Phase 3c — Detection and banning

Everything before this prevents. Nothing noticed. There was no access log,
no alert, and no mechanism that stopped a patient attacker — the rate
limit slows guessing to 5/min but never ends it.

**Traefik access log**, JSON, 4xx/5xx only. Successful playback would write
a line per HLS segment and drown the signal. The file is root-only `0640`
and rotated daily for 14 days, because Jellyfin sometimes carries an
`api_key` in the query string and `RequestPath` includes it. `logrotate` is
installed by the role: it is absent from the minimal Oracle image, so
shipping the config alone would have been an inert file and an unbounded
log.

**fail2ban jail** reading that log, banning after 8 failures in 10 minutes
for 24 hours. Two things about it were not obvious: the ban is written to
`DOCKER-USER` through an ipset, not to `INPUT` where fail2ban's stock
actions go — Docker publishes container ports through its own chains and
never traverses `INPUT`, so a stock ban would have been silently inert (the
same trap the geoblock rule fell into twice). And the filter matches **401
and 429** — a first version counted only 401 and could never fire, because
after three attempts the rate limit answers 429, shielding the attacker
from ever reaching the ban threshold.

`ignoreip` covers the tailnet and the docker bridge — a request from the
host to its own published port arrives as the bridge gateway, so local
checks would otherwise ban the host from its own service.

Verified end to end: `fail2ban-regex` matches real log lines and ignores
unrelated ones, ten failures produced a real ban, and the address landed
in the ipset with a 24-hour timeout.

### Phase 5 — Egress containment

`kubernetes/apps/default/jellyfin/app/networkpolicy.yaml` gains a
`jellyfin-egress` policy. The namespace baseline defines ingress only,
which in Cilium leaves egress wide open — a Jellyfin RCE reached Proxmox,
pfSense, the Synology and every other pod with nothing in the way. A VPS in
front does not help against that: the same request is equally reachable
through the proxy. This is the control that turns "compromise of the
house" into "compromise of one container".

Allowed: DNS to kube-dns, and 443/80 to the internet with RFC1918, CGNAT
and link-local carved out. Without the carve-out, `world` on 443 would
still reach pfSense's web UI. NFS is deliberately absent — `/media` is an
inline nfs volume mounted by the kubelet on the node, so that traffic
never leaves the pod's network namespace.

Verified from inside the pod: TMDb, TheTVDB, the plugin repo and image CDNs
all reachable; pfSense, Proxmox, pve rpcbind and the Synology all blocked;
zero DROPPED flows in Hubble and no errors in the Jellyfin log. Side
effects, both wanted: DLNA/SSDP discovery and UPnP port mapping stop
working.
