# edge_proxy

Traefik on the edge. One entrypoint, one router: `studio.merox.dev` → the
public Jellyfin at `10.57.57.108:8096` over the tailnet.

## Deliberately absent

| | Why |
|---|---|
| Dashboard / `api` | Nothing needs it |
| Docker provider | No daemon socket in an internet-facing container; `/config` is the only source |
| Any second router | `curl -H "Host: sso.merox.dev" https://<edge-ip>` → 404, because that router does not exist here |
| State | No DB, no tunnel, no backup set. Borrowed tenancy — losing the host costs one DNS record |

## network_mode: host

Traefik binds `:80`/`:443` directly, so firewall rules match the real port —
none of the DNAT traps `DOCKER-USER` needs on `vps01`. Cost: every listener is
a host listener, so ping is pinned to `127.0.0.1:8082` and the container runs
`cap_drop: ALL` + `NET_BIND_SERVICE`.

Certificates: DNS-01 via Cloudflare, same token as `vps01`. `:80` only serves a
308. Both hosts can hold a cert for the same name (LE allows 5 duplicates/week).

## Ops

```sh
sudo docker logs traefik --tail 50
curl -skI https://127.0.0.1/ -H "Host: studio.merox.dev"   # 302
curl -skI https://127.0.0.1/ -H "Host: sso.merox.dev"      # 404 — must stay 404
sudo jq -r '.cloudflare.Certificates[].domain.main' /srv/docker/edge/traefik/data/acme.json
```
