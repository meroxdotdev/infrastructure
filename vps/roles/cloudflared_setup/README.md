# cloudflared_setup

Deploys the Cloudflare Tunnel connector container on the VPS
(`docker-compose.yml.j2` — just `cloudflared tunnel run` with a token from
`cloudflared.env.j2`). That's all this role manages.

## The routing table lives outside git

Which hostname routes to which local service is configured in the
Cloudflare dashboard (**Zero Trust → Networks → Tunnels → the VPS
tunnel → Public Hostname** tab), not in any file this role deploys. A
fresh `make setup` brings the container back, but every hostname 404s
until these are re-entered by hand.

Current mappings (confirm against the dashboard — this is the one part of
the tunnel that can drift without git noticing):

| Hostname | Service | Notes |
|---|---|---|
| `inside.merox.dev` | `https://172.25.10.2:443` | Traefik, over the docker bridge — **not** the published host port. See [docs/jellyfin-public-exposure.md](../../../docs/jellyfin-public-exposure.md) for why (`:443` on the host is reserved for the public Jellyfin entrypoint). |
| `sso.merox.dev` | `http://172.25.10.72:9000` | Authentik, directly |
| `rmt.merox.dev` | `http://172.25.10.72:9000` | Authentik's embedded outpost proxy (Guacamole) |
| (catch-all) | `http_status:404` | |

Compare to the Kubernetes-side tunnel
([`kubernetes/apps/network/cloudflare-tunnel/app/resources/config.yaml`](../../../kubernetes/apps/network/cloudflare-tunnel/app/resources/config.yaml)),
where the equivalent ingress config is a file in git and comes back
automatically on any cluster rebuild — this table is the VPS-side
equivalent, kept here by hand because the tunnel itself has nowhere to
read it from.
