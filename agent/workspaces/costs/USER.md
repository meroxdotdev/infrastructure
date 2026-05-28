# USER.md — Merox

- **Name:** Merox (Robert)
- **Timezone:** Europe/Bucharest
- **Communication language:** Romanian

## Critical services that need backup

- **Joplin Server** (notes) — Postgres DB
- **Authentik** (SSO) — Postgres DB
- **Longhorn PVCs** — via Garage S3
- **Garage S3** — object storage for Longhorn
- **Portainer** — config (nice to have)

## Infrastructure repos

- Infrastructure: `meroxdotdev/infrastructure` at `/srv/kubernetes/infrastructure/`
- Docker services: `/srv/docker/`
