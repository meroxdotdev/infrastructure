# edge_base

Prepares the host: tailnet route to the backend, plus the `EDGE-INPUT` chain
that `geoblock_ro`, `egress_guard` and fail2ban write into.

## EDGE-INPUT

`vps01` borrows docker's `DOCKER-USER`. Traefik here runs `network_mode: host`,
so there is none — this role builds the equivalent.

```
INPUT
  -j ts-input                                    tailscaled owns this
  -j EDGE-INPUT
       1 DROP tcp/443 not in geoblock_allow      geoblock_ro    ┐ inserted
       2 DROP tcp/443 in f2b-jellyfin            fail2ban       │ at pos 1
       3 DROP tcp/443 above the cap              egress_guard   ┘
       4 ACCEPT tcp/80,443                       this role, appended
  ESTABLISHED ACCEPT … REJECT                    Oracle cloud-image ruleset
```

- Jump goes **before** the conntrack ACCEPT, so a ban cuts live streams.
- ACCEPT is appended, DROPs are inserted — order holds whatever runs first.
- Unmatched traffic RETURNs; the rest of the Oracle ruleset is untouched.

**Not in `/etc/iptables/rules.v4`.** `netfilter-persistent save` would capture
the ipset rules too; at boot the restore runs before the sets exist, fails, and
the host comes up with no firewall. Static rules live in
`edge-firewall.service` (`After=netfilter-persistent`, `Before=network-pre`),
dynamic ones in their own boot units.

## Tailscale

`tailscale set`, never `tailscale up` — ansible reaches this host over the
tailnet and `up` would drop the session. Fails loudly if not logged in.

`--accept-routes` is mandatory: without it pfSense's `10.57.57.0/24` is
received and ignored, and the backend just times out. The role verifies the
backend answers before Traefik goes in front of it.

## Ops

```sh
sudo iptables -S EDGE-INPUT
sudo /usr/local/sbin/edge-firewall.sh     # re-apply
tailscale debug prefs | grep RouteAll     # must be true
bash scripts/edge-verify.sh
```
