# egress_guard

Automatic circuit breaker for outbound data transfer. Runs on both Oracle hosts.

## Why it exists

vps01's tenancy is **Pay As You Go**. Oracle includes 10 TB/month of egress;
past that it bills roughly $0.0085/GB. An OCI budget alert only notifies — it
does not stop traffic. Exposing Jellyfin publicly adds the first workload
capable of moving real volume, so the exposure needs a hard stop rather than a
warning.

edge-fra's tenancy is **Always Free**, where an overage is throttling rather
than an invoice. The guard runs there anyway: the allowance belongs to the
person who lent the account, and spending all of it is not a thing to leave to
chance.

## How it bounds the bill

An hourly timer reads the monthly TX counter for the billed uplink and, above
`egress_guard_cut_tb`, inserts a `DROP` for tcp/443 in `egress_guard_chain` —
`DOCKER-USER` on vps01, `EDGE-INPUT` on edge-fra, for the reasons in
[`geoblock_ro`](../geoblock_ro/README.md). The exact value lives in the vault,
not here — a public repo stating the cut-off tells anyone how much traffic to
push to take the service down.

That is a guarantee, not a hope: the home uplink measures ~430 Mbps, so at most
~0.19 TB can move between two hourly checks — comfortably inside the 10 TB
allowance even at the worst case, so **an egress bill is not reachable**.

Normal use never comes close. Three concurrent 10 Mbps streams for four hours a
day is ~1.6 TB/month, and the baseline before Jellyfin was ~16 GB.

## What it does and does not cut

| | |
|---|---|
| tcp/443 (Jellyfin, public) | **dropped** above the threshold |
| SSH | untouched |
| Cloudflare tunnel | untouched — outbound, and carries dashboards, not video |
| Tailscale | untouched |

The rule is removed automatically on the next run once the monthly counter
rolls over, so recovery needs no intervention.

## Deliberate design choices

**Fails open, not closed.** If `vnstat` cannot be read the script exits without
touching iptables. A monitoring hiccup must not take the service down; the next
hourly run retries.

**Reads the physical uplink, not a bridge.** `vnstat --json m` returns docker
bridges first, so the interface is passed explicitly — billing follows
`enp0s6`, not `br-*`.

**Identical argument order in `-C` and `-I`.** Otherwise the existence check
never matches and the rule is re-inserted on every run.

## Operations

```sh
/usr/local/sbin/egress-guard.sh                 # run a check now
systemctl list-timers egress-guard.timer        # next run
vnstat -i enp0s6 -m                             # monthly history
iptables -L DOCKER-USER -n --line-numbers       # vps01: is the block in place?
iptables -L EDGE-INPUT  -n --line-numbers       # edge-fra: same
cat /var/lib/egress-guard/blocked-since         # when it tripped, if it did
```

Manual unblock, if you accept the cost:

```sh
iptables -D <chain> -p tcp --dport 443 -j DROP -m comment --comment egress-guard
```

It will be re-applied within the hour unless `egress_guard_cut_tb` is raised.

## Related

Geographic filtering on the same port lives in
[`geoblock_ro`](../geoblock_ro/README.md); both write to the same chain, and
both take it from a variable for the same reason.
Context in [`docs/jellyfin-public-exposure.md`](../../../docs/jellyfin-public-exposure.md).
