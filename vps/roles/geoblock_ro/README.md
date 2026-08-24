# geoblock_ro

Restricts Traefik's public entrypoint to prefixes announced by Romanian
consumer ISPs, plus anything in `geoblock_extra_allow`. Everything else is
dropped in the kernel, before the TLS handshake.

It exists because `media.merox.dev` is the only thing served directly on the
VPS public address — see
[`docs/jellyfin-public-exposure.md`](../../../docs/jellyfin-public-exposure.md).

## Allow by operator, not by country

The first version used an ipdeny country list and **leaked badly**: a phone on
Surfshark reached the service from several countries. Every exit that got
through was a hosting network *registered* in Romania and therefore inside the
country list:

| Address observed | ASN | Holder |
|---|---|---|
| 146.70.120.36 | AS9009 | M247 Europe SRL |
| 37.120.193.230 | AS9009 | M247 Europe SRL |
| 193.19.207.93 | AS203020 | HostRoyale |
| 138.199.29.188 | AS212238 | Datacamp |
| 66.249.81.200 | AS15169 | Google (crawler) |

M247 alone announces ~4250 IPv4 prefixes, against ~610 for every Romanian
consumer ISP combined. Country-level geo-IP cannot separate a person at home
from a datacenter in the same country, so the model was wrong — not the data.
Both the aggregated and the full ipdeny files list `146.70.0.0/16` as Romania.

Allowing specific consumer ISPs covers the people this is for and excludes
datacenters by construction. Prefixes come from RIPEstat's announced-prefixes
API, refreshed daily.

**Someone on a smaller regional ISP will be blocked.** Add their ASN to
`geoblock_asns`, or their address to `geoblock_extra_allow`.

## What this is and is not

It is noise reduction. It drops automated scanning — hundreds of packets within
the first hour — and it now also drops commodity VPN exits and crawlers.

It is **not** a security boundary. Anyone determined enough to find a VPN exit
on a consumer ISP walks through. The controls that actually matter are
authentication, keeping Jellyfin patched, the egress cap in
[`egress_guard`](../egress_guard/README.md), and the pod egress policy in
`kubernetes/apps/default/jellyfin/app/networkpolicy.yaml`.

## Mechanics

| Piece | Role |
|---|---|
| `/usr/local/sbin/geoblock-refresh.sh` | fetches prefixes, rebuilds the set, re-applies the rule |
| `geoblock.timer` | daily, `RandomizedDelaySec=1h` |
| `geoblock.service` | runs at every boot |
| `DOCKER-USER` | the chain forwarded traffic to containers traverses |

Re-applied at boot because **`DOCKER-USER` is flushed when docker or the machine
restarts**. UFW is irrelevant here — docker publishes ports through its own
chains and bypasses it (and UFW is not even installed on this host).

### The rule took three attempts

Worth writing down, because two of them looked correct and silently were not.

`--dport 443` matched nothing. Docker DNATs in `nat PREROUTING`, so by the time
a packet reaches `FORWARD` its destination port is already the container port.
With the mapping at `443:8443`, a rule against port 443 never fires — which is
how geoblocking shipped completely inert.

`--ctorigdstport 443` was worse. It also matches connections a container
*initiates* towards an external port 443, whose original destination port is
likewise 443, so it dropped the replies to every outbound HTTPS request the
containers made.

`-d <traefik-container-ip> --dport 8443` is unambiguous: it can only describe
traffic being forwarded to the public entrypoint.

## Safety

- Prefix lookups write to a temp file; on failure the previous copy is kept.
- The set is built in a `_tmp` set and goes live via `ipset swap`, so there is
  never a window with an empty set.
- Below `geoblock_min_prefixes` the script **aborts** without touching anything.
  `nomatch` entries do not count towards that floor.

## Operations

```sh
ipset list geoblock_allow | grep -c '^[0-9]'   # prefix count (~614)
ipset test geoblock_allow <address>            # would this address get in?
iptables -L DOCKER-USER -n -v --line-numbers   # rule present, and its counters
systemctl list-timers geoblock.timer           # next refresh
/usr/local/sbin/geoblock-refresh.sh            # force a refresh now
```

Someone travelling abroad: add their address to `geoblock_extra_allow`, or
invite them to the tailnet — `100.64.0.0/10` is already allowed.

Full disable: `geoblock_enabled: false` + re-run the role.
