# geoblock_ro

Restricts Traefik's public port (`443`) to prefixes allocated to Romania, plus
anything listed in `geoblock_extra_allow`. Everything else is dropped in the
kernel, before the TLS handshake.

It exists because `media.merox.dev` is the only thing served directly on the
VPS public IP — see
[`docs/jellyfin-public-exposure.md`](../../../docs/jellyfin-public-exposure.md).

## Why not a Traefik plugin

All three common geoblock plugins read `X-Forwarded-For` by default. On an
entrypoint exposed directly to the internet there is no proxy in front, so the
client fully controls that header: send `X-Forwarded-For: <Romanian IP>` and
the geoblock disappears. On top of that the Traefik image is pinned to
`:latest`, so a plugin adds a dependency that can break on a nightly update.

`ipset` has neither problem and is cheaper: the connection dies on the first
SYN, not after negotiating TLS.

## How it works

| Piece | Role |
|---|---|
| `/usr/local/sbin/geoblock-refresh.sh` | downloads zones, rebuilds the set, re-applies the rule |
| `geoblock.timer` | daily, with `RandomizedDelaySec=1h` |
| `geoblock.service` | runs at every boot |
| `DOCKER-USER` | the chain traffic to published container ports traverses |

The rule is re-applied at boot because **`DOCKER-USER` is flushed when docker
or the machine restarts**. UFW does not help here: docker publishes its ports
through its own chains and bypasses UFW entirely.

## Safety

- Zone files download to a temporary path; on failure the previous copy is kept.
- The set is built in a `_tmp` set and goes live via `ipset swap`, so there is
  never a window with an empty set.
- Below `geoblock_min_prefixes` (default 100) the script **aborts** without
  touching anything. A corrupted download cannot lock out the service.

## Operations

```sh
ipset list geoblock_allow | head -20         # what is in the set
ipset list geoblock_allow | grep -c '^[0-9]' # prefix count
iptables -L DOCKER-USER -n --line-numbers    # is the rule there?
systemctl list-timers geoblock.timer         # next run
/usr/local/sbin/geoblock-refresh.sh          # force a refresh now
```

Someone travelling abroad: add their IP to `geoblock_extra_allow` and run
`make setup`. Alternatively invite them to the tailnet — `100.64.0.0/10` is
already allowed.

Full disable: `geoblock_enabled: false` + `make setup`.

## Limits

Geo-IP is not exact. Roaming, VPNs and some mobile networks can appear to come
from another country. This is a noise-reduction layer — roughly 80% of
automated scanning — not a security boundary. That remains the password, the
rate limit, and keeping Jellyfin patched.
