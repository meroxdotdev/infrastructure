# authentik_setup

Deploys [Authentik](https://goauthentik.io/) SSO on the Oracle Cloud Docker server via Ansible.

## What it deploys

| Container | Image | IP |
|---|---|---|
| authentik-postgresql | postgres:16-alpine | 172.25.10.70 |
| authentik-redis | redis:alpine | 172.25.10.71 |
| authentik-server | ghcr.io/goauthentik/server | 172.25.10.72 |
| authentik-worker | ghcr.io/goauthentik/server | 172.25.10.73 |

All containers join the existing `network-cloud-merox` Docker network alongside Traefik.

## Prerequisites

- Traefik running on Oracle (role: `traefik_setup`)
- `network-cloud-merox` Docker network exists
- Cloudflare Tunnel (`one`) has a route: `sso.merox.dev` → `http://172.25.10.72:9000`
- DNS: `sso.merox.dev` CNAME managed by Cloudflare Tunnel (do NOT add an A record)

## Required vault variables

```yaml
authentik_pg_pass: "<openssl rand -base64 36>"
authentik_secret_key: "<openssl rand -base64 60>"   # min 50 chars
authentik_admin_password: "<strong password>"        # sets akadmin on deploy
```

Add to vault:
```bash
make vault-edit
```

## Deploy

```bash
make authentik-setup
```

Idempotent — safe to re-run. On subsequent runs it only updates changed files and restarts containers if needed.

## Upgrade

Update `authentik_version` in `defaults/main.yml`, then re-run:
```bash
make authentik-setup
```

Authentik runs DB migrations automatically on startup.

## Backup

A daily cron job (`/usr/local/bin/backup-authentik.sh`, runs at 01:15) dumps PostgreSQL to
`/srv/backups/authentik/` with 7-day retention. Deployed automatically by this role
(re-run `make db-backups-setup` to (re)install it).

For an on-demand dump:

```bash
make authentik-backup
```

This runs the standalone playbook, which dumps PostgreSQL to `/srv/backups/authentik/` (7-day retention).

## Restore

```bash
# Copy backup file to server, then:
docker exec -i authentik-postgresql psql -U authentik authentik < backup.sql
docker restart authentik-server authentik-worker
```

## Post-deploy manual steps

1. Log in at `https://sso.merox.dev/if/admin/` with `akadmin`
2. Configure Google OAuth source: Admin → Directory → Federation & Social Login → Add → Google
3. Configure Traefik forward auth for each service: add label `traefik.http.routers.<name>.middlewares=middlewares-authentik@file`

## Architecture

```
Internet
  └── Cloudflare Tunnel (one) → systemd cloudflared on Oracle
        └── http://172.25.10.72:9000 → authentik-server
              ├── authentik-postgresql (172.25.10.70)
              └── authentik-redis     (172.25.10.71)

Traefik forward auth (for Oracle services):
  Request → Traefik → middlewares-authentik@file
    └── http://authentik-server:9000/outpost.goauthentik.io/auth/traefik
          ├── valid session → forward to service
          └── no session    → redirect to sso.merox.dev/login
```
