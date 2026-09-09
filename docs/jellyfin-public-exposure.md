# Jellyfin — public exposure, retired

**Nothing in this estate is reachable from the internet.** This file is the
record of what was, and the two things worth keeping from it.

Retired 2026-09-08/09: the `edge-fra` instance is deleted, `jellyfin-public` and
`radarr-public` are gone from the cluster, and `vps01`'s Traefik publishes on
its tailnet address only.

## What it was

A second Oracle instance in Frankfurt terminated TLS for a curated 1080p
Jellyfin library — 30 ms to viewers against 165 ms from Phoenix — on borrowed
tenancy, stateless, geoblocked to Romania in the kernel. The library lived on
`pve-2`'s SSD pool so streaming to friends never woke the SAS array, and it was
a separate instance from the personal one on purpose: merging them would have
put the 4K library behind the process facing the internet.

## The two things worth keeping

**A router that does not exist on a port cannot be reached through it.** An IP
allowlist does not stop someone pointing their own Cloudflare zone at a known
origin; an entrypoint carrying no matching router does. That is what the
`https` / `public` split on `vps01` defended, and why `sso.merox.dev` could not
be reached straight off the public IP with a forged Host header.

**Collapsing a defence does not preserve what it defended.** When the split was
removed the property had to be re-established somewhere else — Traefik now
publishes on the tailnet address rather than `0.0.0.0`, which keeps it in git
instead of a console setting. `geoblock_ro` went off with the entrypoint it
guarded, and the OCI security list still allows `TCP 443` from `0.0.0.0/0`, so
a future `0.0.0.0` bind would silently reopen the hole. Closing that port is
the second layer, and the only thing that makes such a bind fail loudly.

## What it cost while it stood

Pi-hole answers `*.cloud.merox.dev` with `vps01`'s tailnet address, so every
internal client reached host `:443` — the `public` entrypoint, where none of the
internal routers existed. Joplin, Authentik, Guacamole and Homepage all returned
a bare 404 over the tailnet for nine days. It surfaced as a phone that would not
sync.

```sh
sudo grep joplin /var/log/traefik/access.log | jq -r 'select(.RouterName == null)'
```

`RouterName: null` on a 404 is the signature: the request arrived and matched no
router, rather than reaching a router whose backend was down. A 502 would have
meant the opposite.

## If a public listener is wanted here again

`git show 6b34494` has the entrypoint split. `geoblock_enabled` and
`fail2ban_jellyfin_enabled` in `group_vars/vps_servers/vars.yml` turn its
filtering back on. On a rebuilt edge none of that applies — `edge_proxy` carries
its own copy.
