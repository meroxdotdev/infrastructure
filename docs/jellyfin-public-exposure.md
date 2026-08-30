# Jellyfin — public exposure

`studio.merox.dev` served to family and friends without publishing the home IP.
What faces the internet is a **second, dedicated Jellyfin** with a curated 1080p
library on SSD. The personal instance (4K, SAS) is never reachable from outside.

**Status:** live on `edge-fra` since 2026-08-30. DNS, certificate, geoblock,
fail2ban and the egress guard all verified end to end with
`bash scripts/edge-verify.sh` (18 checks). Only `vps01`'s old public path is
still to be retired — see below.

Build log: `git show 9385285:docs/jellyfin-public-exposure-log.md`.

## Architecture

```
Viewers ──▶ studio.merox.dev (grey-cloud A record, no CDN)
                 │
          <edge-ip>:443                edge-fra, OCI eu-frankfurt-1
          ipset DROP: non-RO ISPs      kernel, before TLS
          fail2ban ban set             kernel, before TLS
          Traefik, network_mode: host  only the jellyfin router exists
                 │  Tailscale, 21 ms direct
                 ▼
          pfSense subnet router ──▶ 10.57.57.108:8096   jellyfin-public
                                    /media (ro) = rpool/jellyfin-public  SSD

LAN / Tailscale ──▶ media.merox.dev ──▶ 10.57.57.107   personal, untouched
```

No new inbound ports at home. The edge is the only public listener.

## Why Frankfurt

`vps01` (us-phoenix-1) served this until 2026-08-30 at **165 ms** to RO viewers.
`edge-fra` is ~30 ms from them, 21 ms from the house, direct path, no DERP.

`VM.Standard.A1.Flex`, 2 OCPU / 12 GB, arm64, **borrowed Always Free tenancy**.
Hence: no state, no DB, no tunnel, no backup set. Losing it costs one DNS
record. Everything that must outlive the house stays on `vps01`.

## Two instances, on purpose

| | Personal | Public |
|---|---|---|
| Library | 1.11 TB, 4K, SAS array | curated 1080p, SSD |
| Reachable from internet | no | yes |
| Accounts, watch history | yours | two shared accounts |
| GPU | Quadro P2200 | time-sliced share of the same card |
| Longhorn backup | yes | no, fully reconstructible |

RCE in the public instance reaches a read-only view of re-encoded films and
nothing else — not the personal library, the *arr stack or the watch history.
No 4K exists on that filesystem, so it cannot be misconfigured into existence.
Streaming never wakes the SAS array: SSD ~1.5 W vs ~60-80 W for twelve drives.

Content is derived: re-encoded once to H.264 1080p (~6-8 GB), ~50 titles in the
400 GB quota.

**NVENC is not automatic.** `HardwareAccelerationType` defaults to `none`; set
it to `nvenc` in `/config/config/encoding.xml` and restart. PVC state, outside
the backup set — re-do it after any PVC recreation or every stream falls back
to software and takes the single-node control plane with it.

## How the edge is built

`cd vps && make edge-setup`

| Role | Owns |
|---|---|
| [`edge_base`](../vps/roles/edge_base/README.md) | `--accept-routes`, the `EDGE-INPUT` chain |
| [`edge_proxy`](../vps/roles/edge_proxy/README.md) | Traefik, host network, one router |
| [`geoblock_ro`](../vps/roles/geoblock_ro/README.md) | RO consumer-ISP allow set, dropped before TLS |
| [`egress_guard`](../vps/roles/egress_guard/README.md) | hourly cap on the borrowed 10 TB allowance |
| `security_hardening` | SSH, fail2ban jail on failed logins |

Same filtering roles as `vps01`, differing by one variable: the chain. `vps01`
uses docker's `DOCKER-USER`; the edge has none, so `edge_base` builds
`EDGE-INPUT`. That removes the DNAT traps documented in `geoblock_ro` — here a
rule against port 443 matches port 443.

## Why the backend leg stays on the tunnel

Recurring question: would the edge reach home faster over the plain internet
than through WireGuard? Measured 2026-08-30, edge to backend, 184 MB in ten
parallel streams: **141 Mbps sustained over 11 s**, with `tailscaled` at
70-110% CPU on a 2-core box throughout.

So the tunnel is not free, and 141 Mbps is most likely its ceiling rather than
the uplink's — userspace WireGuard, one end an Ampere A1 core, the other
pfSense on an N100. Going direct would genuinely raise it.

It still stays, because demand cannot exceed **90 Mbps**: two accounts, three
sessions each, capped at 15 Mbps. The tunnel carries 1.6x the maximum the
account policy permits. That is headroom, not abundance — **raise the per-user
caps or add accounts and this becomes the binding constraint**, at which point
re-measure before assuming it still holds.

Latency does not change either, which is the part that gets assumed. The path
is already direct — `via 92.84.33.233:41641 in 20ms`, no DERP — over exactly
the route a plain TCP connection would take. WireGuard adds microseconds of
crypto, not milliseconds of routing.

What going direct would cost: an inbound port at home, ending the property the
whole design rests on; a plaintext `http://` backend across the public internet
carrying media, session tokens and the api_key Jellyfin puts in query strings,
so a second certificate and renewal path would be needed to fix it; and a
source-restricted firewall rule keyed to an **ephemeral** Oracle address, which
would break silently the first time it changes. In exchange for throughput the
account caps forbid using.

The tunnel's one genuine risk is a **DERP fallback**: if NAT traversal breaks,
Tailscale relays through a shared server and quality drops hard, silently.
`scripts/edge-verify.sh` fails on that rather than leaving it to be discovered
by someone complaining that playback stutters.

## Congestion control

A stream now crosses two TCP connections, and they are tuned separately:

```
viewer ──TCP──▶ Traefik on edge-fra ──TCP──▶ jellyfin-public pod
                bbr, edge_base               bbr, Talos sysctl
```

The Talos sysctl only ever governed the second leg. The first one — the leg
that decides whether playback stalls — ran on the image default, cubic, until
2026-08-30. The measurement behind choosing BBR is in
`talos/patches/global/machine-sysctls.yaml`: 30 Mbps on cubic against 103 on
BBR over the same tunnel at 165 ms. At Frankfurt's ~30 ms the gap on a clean
link is far smaller, but these viewers are on Romanian mobile networks, and
loss is where cubic collapses its window and BBR does not.

**A sysctl alone does not apply it.** Accepted sockets inherit the algorithm
from the listening socket, so Traefik keeps serving new connections with
whatever was default when its listener was created. `edge_base` restarts
Traefik when the value changes; after any manual sysctl change, restart it by
hand. Verify against live connections, never against the sysctl:

```sh
ssh edge-fra 'ss -tin state established "( sport = :443 )" | grep -oE "bbr|cubic" | sort | uniq -c'
```

Not done: HTTP/3. It would help most on exactly these lossy mobile links, but
it needs UDP 443 through OCI, `EDGE-INPUT` and a second geoblock rule, and the
native clients (Android TV, Swiftfin, Kodi) do not speak it — only the web
client would benefit.

## Jellyfin settings

**Known Proxies needs no edge-specific entry, and this was measured, not
assumed.** `10.57.57.80` + `10.0.0.0/8` is enough: Cilium SNATs to the node with
`externalTrafficPolicy: Cluster`, so the tailnet address never appears as a
client. Verified 2026-08-30 with a deliberate failed login through the edge:

```
Authentication request for "__nonexistent__" has been denied (IP: "92.84.33.233")
RemoteClientBitrateLimit: 15000000, RemoteIP: "92.84.33.233", IsInLocalNetwork: False
```

The real viewer address arrives intact and `IsInLocalNetwork: False` means the
remote restrictions apply. `LocalNetworkSubnets` is empty, so the tailnet is not
treated as LAN either. Re-run that check after anything that changes the path.

> `Cluster` not `Local` — Cilium L2 announcements are incompatible with `Local`
> on this topology. **Back at 3 nodes, add the other node IPs to Known Proxies.**

Configured, read from the running instance 2026-08-30:

| Account | Remote bitrate | Max sessions | Hidden from login |
|---|---|---|---|
| `admin` | unlimited | unlimited | yes |
| `prieteni` | 15 Mbps | 3 | yes |
| `familie` | 15 Mbps | 3 | yes |

Server-wide: Quick Connect off, session inactivity timeout 30 min, NVENC on.
No native 2FA. One account per person — shared accounts collide in Continue
Watching and cannot be revoked individually.

On `10.11.11`. `10.11.7` fixed an unauthenticated RCE (CVE-2026-35033) and a
9.9 path traversal (CVE-2026-35031) — never more than one patch behind.

PVC state, not git: record changes in [jellyfin-post-restore.md](jellyfin-post-restore.md).

**No Authentik in front:** forward auth breaks native clients (Android TV,
Swiftfin, Kodi, Roku). [jellyfin#16956](https://github.com/jellyfin/jellyfin/issues/16956).

## Manual steps

Steps 1-2 are in the **borrowed tenancy's** console, not vps01's.

| # | Where | What | |
|---|---|---|---|
| 1 | Tailscale | `tag:edge-proxy` on the node — one grant, `10.57.57.108:8096` only | done |
| 2 | OCI → VCN → Security List | Ingress `TCP 443` from `0.0.0.0/0`. Only 443 — see below | done |
| 3 | Cloudflare DNS | `A` · `studio` · `<edge-ip>` · **grey cloud** ← the cutover | done |
| 4 | Jellyfin admin | Accounts, bitrate caps, Quick Connect off | done |
| 5 | OCI → VCN → Security List | Replace ingress `TCP 22` `0.0.0.0/0` with the home address. Tailscale is outbound and unaffected | |
| 6 | Jellyfin admin → General | Disclaimer + Custom CSS from `kubernetes/apps/default/jellyfin-public/branding/` | |
| 7 | vps01, a day later | Retire the old path, below | |

**Tag the node before opening 443.** Untagged it falls under `autogroup:member`
in the tailnet ACL, which grants `dst: *` — an internet-facing box with full
reach into the house. Tagged, it reaches one address and one port; pve's SSH,
pfSense, the k8s gateway and the personal Jellyfin on `.107` are all refused.

**Port 80 is deliberately absent**, in OCI and in Traefik. Certificates come
from DNS-01, so it plays no part in issuance; it would serve only a 308 for
someone typing the host without a scheme, and it would be the one public
listener not behind the geoblock set, which matches on `--dport 443`. The cost
is that `http://studio.merox.dev` fails at connect instead of redirecting —
hand out the full `https://` URL.

**The public address is ephemeral and stays that way.** The tenancy has no quota
for reserved public IPs — the console offers only "No public IP" and "Ephemeral
public IP" — so the operational rule is: reboot from the OS (keeps the address,
verified 2026-08-30), never Stop/Start from the OCI console (releases it). If it
does change, it costs one DNS record and one line in `~/.ssh/config`; nothing in
this repo hardcodes it.

Grey cloud means no Cloudflare WAF, rate limiting or bot protection — all
filtering is on the edge: ipset for geography, Traefik for rate limiting.

Disclaimer and CSS live in `kubernetes/apps/default/jellyfin-public/branding/`;
Jellyfin keeps them in the config PVC, so they travel with the NVENC setting
and anything that recreates the PVC loses all three.

## Retiring the old path on vps01

Not part of the cutover — DNS TTL means both serve for a while. After a day:

1. OCI (original tenancy) → delete the `443` ingress rule.
2. Drop the `jellyfin` / `jellyfin-auth` routers from
   `vps/roles/traefik_setup/templates/config.yml.j2`.
3. Republish `443` to the `https` entrypoint in `docker-compose.yml.j2` — the
   bridge detour only existed to free the host port.
4. `geoblock_enabled`, `egress_guard_enabled`, `fail2ban_jellyfin_enabled` →
   `false` in `vps_servers/vars.yml`.
5. `make setup`.

vps01 is then back to what its README claims: no open inbound ports.

## Verification

```bash
bash scripts/edge-verify.sh
```

Firewall chain and ordering, geoblock set, fail2ban jail, both timers, Traefik
health, backend over the tailnet, DNS, cert issuer, and the one that matters:
`sso.merox.dev` / `rmt.merox.dev` / `traefik.cloud.merox.dev` must return **404**
on the edge's public address. A `200` means a router is bound that should not
exist — check `edge_proxy/templates/config.yml.j2`.

Before the OCI rule exists the external section is skipped, not failed.

By hand: RO mobile data works; non-RO VPN dies at TCP level (kernel drop, not
403); six bad logins return 429; a transcode plays; `media.merox.dev` on the LAN
still resolves to `10.57.57.101` at full bitrate.

## Rollback

| Step | Undo |
|---|---|
| DNS | point `studio` back at vps01 — it still serves this name |
| OCI | delete the `443` ingress rule |
| Traefik | `git revert` + `make edge-setup` |
| Geoblock | `geoblock_enabled: false` + `make edge-setup` |
| The whole edge | terminate the instance; nothing on it is unique |

## Accepted risks

| Risk | Mitigation |
|---|---|
| Borrowed tenancy can vanish without notice | No state on it; recovery is one DNS record |
| Ephemeral public IP, no reserved-IP quota | Survives OS reboots; only a console Stop/Start releases it |
| UHD remuxes exceed 103 Mbps | cap remote bitrate; transcode instead of direct play |
| Geo-IP misfires on roaming and VPNs | `geoblock_extra_allow`, or invite them to the tailnet |
| Unauthenticated Jellyfin CVE | Renovate tracks the digest; egress policy limits blast radius |
| The account owner's 10 TB allowance | `egress_guard` cuts the port hourly at the vaulted threshold |
| Nothing alerted | access log, fail2ban, optional healthchecks ping |
| Two public origins until vps01 is retired | same backend; removed in the step above |
| Provider AUP on copyrighted material | private, authenticated, geoblocked — not a discoverable target |

Sharing a library outside the household is a legal exposure separate from any
provider clause, and on a borrowed account it is someone else's name on the
terms. Say so to them.
