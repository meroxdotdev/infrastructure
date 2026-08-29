# Jellyfin — public exposure

Serving `studio.merox.dev` to family and close friends over the internet, from
the existing Oracle VPS, at zero extra cost, without publishing the home IP.

What faces the internet is a **second, dedicated Jellyfin** with its own
curated 1080p library on SSD. The personal instance keeps the full 4K library
on the SAS array and is never reachable from outside.

**Status:** built and verified end to end. The Oracle ingress rule for 443 is
currently removed, so nothing is publicly reachable until it's put back
(manual steps below). Jellyfin account settings (Phase 4) are the one part
still pending — do those before reopening the port.

Measurements, rejected alternatives and the build log lived in
`jellyfin-public-exposure-log.md`, removed 2026-08-29 once the build was
done. Git still has it: `git show 9385285:docs/jellyfin-public-exposure-log.md`.

---

## Architecture

```
Viewers ──▶ studio.merox.dev (grey-cloud A record, no CDN)
                 │
          <vps-public-ip> : 443        Oracle VPS, us-phoenix-1
          ipset DROP: non-RO ISPs      kernel, before TLS
          fail2ban ban set             kernel, before TLS
          Traefik entrypoint `public`  ONLY the jellyfin router
                 │  Tailscale (WireGuard)
                 ▼
          pfSense subnet router ──▶ 10.57.57.108:8096
                                    jellyfin-public
                                      /media (ro) = rpool/jellyfin-public  SSD

LAN / Tailscale ──▶ media.merox.dev ──▶ 10.57.57.107  personal, untouched
                                          /media (ro) = media/library  SAS, 4K
```

The home network gains **no new inbound ports**. The only public listener is
the VPS.

## Two instances, on purpose

| | Personal | Public |
|---|---|---|
| Library | 1.11 TB, 4K, SAS array | curated 1080p, SSD |
| Reachable from internet | no | yes |
| Accounts, watch history | yours | two shared accounts |
| GPU | Quadro P2200 | time-sliced share of the same card |
| Longhorn backup | yes | no, fully reconstructible |

A remote code execution in the public instance reaches a container with a
read-only view of re-encoded films and nothing else — it can't see the
personal library, the *arr stack, or the watch history. Friends can't watch
4K because there's no 4K on that filesystem — a fact about storage, not a
policy someone can misconfigure. Streaming to friends never wakes the SAS
array either: the SSD path costs ~1.5 W vs ~60-80 W for the twelve SAS
drives.

Content is *derived*: films are re-encoded once from the main library to
H.264 1080p (~6-8 GB each), so ~50 titles fit the 400 GB quota.

Hardware acceleration is **not** automatic once the GPU is attached —
`HardwareAccelerationType` defaults to `none` and must be set to `nvenc` in
`/config/config/encoding.xml`, then restarted. That's PVC state, not git,
and this instance is deliberately outside the backup set, so it must be set
again after any PVC recreation or every stream falls back to software and
takes the node with it (single-node cluster — nowhere for the control plane
to move if a transcode takes the machine).

## Jellyfin settings (PENDING)

**Known Proxies** (Admin → Networking) — add to the existing `10.57.57.101`:

```
10.57.57.101, 10.57.57.80, 100.72.22.38
```

`10.57.57.80` is the node (Cilium SNATs with `externalTrafficPolicy:
Cluster`); `100.72.22.38` is the VPS tailnet address if the source survives.
Without correct Known Proxies, `100.64.0.0/10` being a trusted LAN Network
means every public viewer is treated as local — no remote bitrate limit and
no remote restrictions.

> `externalTrafficPolicy` is deliberately `Cluster`, not `Local` — Cilium's
> L2 announcements are incompatible with `Local` on this topology. **When
> returning to 3 nodes, add the other node IPs to Known Proxies too** —
> that's the only part of this design that depends on node count.

Per public account:

| Setting | Value |
|---|---|
| Remote streaming bitrate limit | 8-12 Mbps |
| Max simultaneous user sessions | 2 |
| Allow media downloads | off |
| Manage the server | off |
| Hide from login screen | on — the login page lists users by default |

Server-wide: **Quick Connect off**, admin account hidden and used only from
the LAN, session inactivity timeout on. Jellyfin has no native 2FA. One
account per person, not a shared one — on a shared account "Continue
Watching" collides between viewers and access can't be revoked individually.

Jellyfin is on `10.11.11`, current stable. `10.11.7` fixed an
unauthenticated RCE (CVE-2026-35033) and a CVSS 9.9 path traversal
(CVE-2026-35031) — don't fall more than one patch behind.

State lives in the PVC, not git — record changes in
[jellyfin-post-restore.md](jellyfin-post-restore.md).

**Why not Authentik in front:** forward auth breaks native clients (Android
TV, Swiftfin, Kodi, Roku) — they can't complete a browser login flow. Open
upstream request: [jellyfin#16956](https://github.com/jellyfin/jellyfin/issues/16956).

## Manual steps

Nothing below is in git.

| # | Where | What |
|---|---|---|
| 1 | Cloudflare Zero Trust → Tunnels → VPS tunnel | `inside.merox.dev`: service `https://localhost:443` → `https://172.25.10.2:443` |
| 2 | VPS | `git pull && ansible-playbook playbooks/site.yml --tags traefik,geoblock` |
| 3 | Cloudflare DNS | `A` · `media` · `<vps-public-ip>` · **grey cloud** |
| 4 | Oracle → VCN → Security List | ingress `TCP 443` from `0.0.0.0/0` |
| 5 | Jellyfin admin | Known Proxies, accounts, bitrate caps, Quick Connect off (table above) |
| 6 | Jellyfin admin → General | Login disclaimer and Custom CSS, pasted from `kubernetes/apps/default/jellyfin-public/branding/` |

**Order matters, and step 1 must come first.** Traefik already listens on
`172.25.10.2:443`, so repointing the tunnel there works immediately and is
verifiable before anything else changes. Only then does step 2 remap the
host port — doing it the other way round drops `inside.merox.dev` for the
duration. Opening the NSG before step 2 would leave a window where whatever
answers on host `:443` is reachable directly on the public IP. With this
order there is **no downtime** at any point.

Cloudflare WAF, rate limiting and bot protection do **not** apply to a
grey-cloud record — they only run on proxied traffic. All filtering for
`media.merox.dev` happens on the VPS: ipset for geography, Traefik for rate
limiting.

The disclaimer and custom CSS live in
`kubernetes/apps/default/jellyfin-public/branding/`. Jellyfin keeps both in
the config PVC (outside the backup set), so those files are the source and
the dashboard is only where they get pasted — they travel with the NVENC
setting, so anything that recreates the PVC loses all three. The disclaimer
renders as sanitised markdown (blank lines between paragraphs) and is in
Romanian, since that's the audience.

## Verification

```bash
# private services must NOT answer on the public IP
curl -skI https://<vps-public-ip> -H "Host: sso.merox.dev" | head -1   # 404
curl -skI https://<vps-public-ip> -H "Host: rmt.merox.dev"  | head -1   # 404

# private services still work through the tunnel
curl -sI https://sso.merox.dev | head -1                                # 200/302

# Jellyfin answers publicly, and the record is grey
curl -sI https://media.merox.dev | head -1                              # 200/302
dig +short media.merox.dev @1.1.1.1                                     # <vps-public-ip>

# geoblock is live
ipset list geoblock_allow | grep -c '^[0-9]'                            # >1000
iptables -L DOCKER-USER -n --line-numbers | head
```

The first test is the one that matters — a `200` means a router is still
bound to `public`; check `entryPoints` in `config.yml.j2`.

Then by hand: access from Romanian mobile data works; access through a
non-RO VPN dies at the TCP level (dropped in kernel, not a 403); six bad
logins return 429; a transcoding stream plays; and `media.merox.dev` from
the LAN still resolves to `10.57.57.101` at full bitrate.

## Rollback

| Step | Undo |
|---|---|
| NSG | delete the `443` rule — exposure stops instantly |
| DNS | delete the A record |
| Traefik | `git revert` + `make setup`, tunnel back to `:443` |
| Geoblock | `geoblock_enabled: false` + `make setup` |
| BBR | remove the sysctl line, re-apply, rollout restart |

## Accepted risks

| Risk | Mitigation |
|---|---|
| 165 ms to viewers — slower start and seek | inherent to us-phoenix-1; an EU edge is the only fix |
| UHD remuxes exceed 103 Mbps | cap remote bitrate per user; transcode instead of direct play |
| Geo-IP is inexact — roaming and VPNs misfire | `geoblock_extra_allow`, or invite them to the tailnet |
| An unauthenticated Jellyfin CVE | Renovate tracks the digest; stay current; egress policy limits the blast radius |
| Oracle changes the free tier again | already halved once in 2026; a paid EU edge is ~€22/year |
| No detection: nothing logged or alerted | access log, fail2ban, optional healthchecks ping — see build log |
| Egress overage billed on the PAYG tenancy | `egress_guard` cuts the public port hourly at the vaulted threshold, comfortably under the 10 TB allowance — a bill is not reachable |
| Provider AUP on copyrighted material | applies to every host; a private, authenticated, geoblocked instance is not a discoverable target |

Separate from any terms: sharing a library outside the household is a legal
exposure distinct from any provider clause. Named accounts and a small
circle reduce the surface; they do not remove it.
