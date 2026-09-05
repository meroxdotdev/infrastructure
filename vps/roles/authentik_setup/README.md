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

**Pulling the containers on the host does nothing.** Every other service in
this stack (homepage, pihole, joplin, portainer, unbound) runs `:latest`, so
`docker compose pull && up -d` moves them. Authentik is the one service pinned
to an exact tag — `ghcr.io/goauthentik/server:{{ authentik_version }}` — so a
pull re-fetches the *same* image and the UI keeps reporting the old version
next to an "update available" notice. That notice is Authentik checking
upstream, not checking this deployment.

The version only moves from here:

```bash
# 1. edit authentik_version in defaults/main.yml
# 2. re-run the role
make authentik-setup
```

Authentik runs DB migrations automatically on startup, and it does not support
skipping releases arbitrarily — read the release notes between the current tag
and the target before jumping several minors.

Release trains here are quarterly, not monthly: 2026.2 → 2026.5 → 2026.8.
There is no 2026.6 or 2026.7, so 2026.5.6 → 2026.8.1 is one supported step,
not three skipped ones. Check the tag list before assuming a jump is illegal.

### The database password has to match, and once it did not

`authentik_pg_pass` feeds both `POSTGRES_PASSWORD` and
`AUTHENTIK_POSTGRESQL__PASSWORD`, so the vault is the single source for both
sides. But `POSTGRES_PASSWORD` only does anything at initdb. On an existing
volume Postgres ignores it and keeps the password it already has, which means
the vault value and the real one can drift apart in silence and stay that way
for as long as the containers are not recreated.

That is what happened on 2026-09-05. The stack had been up since 4 August on
containers created from an older compose file; the upgrade recreated them,
they came up with the vault password, and the database rejected it:

    FATAL: password authentication failed for user "authentik"

SSO was down for about half an hour. The data was never at risk — the volume
and its 215 tables were untouched, the mismatch was purely on the connection.
The fix was to make the database agree with the vault rather than the other
way round, which is the direction that keeps this role authoritative:

```bash
PW=$(grep -m1 'POSTGRES_PASSWORD:' /srv/docker/oracle-cloud/authentik/docker-compose.yml \
     | sed 's/.*POSTGRES_PASSWORD:[[:space:]]*//; s/^"//; s/"$//')
printf "ALTER USER authentik WITH PASSWORD '%s';\n" "${PW//\'/\'\'}" \
  | docker exec -i authentik-postgresql psql -U authentik -d postgres
docker restart authentik-server authentik-worker
```

`psql -U authentik` over the container's unix socket needs no password, which
is what makes the repair possible at all. Note it pipes the statement in
rather than passing `-c`: psql only interpolates `:'var'` on input it lexes
itself, never on a `-c` string.

Worth knowing before the next upgrade: `Wait for Authentik server to be ready`
allows 120 s, and a release-train jump runs migrations for longer than that. A
timeout on that task alone is not a failed upgrade — check the containers
before concluding anything.

The `# renovate:` comment above `authentik_version` is what keeps this from
drifting silently: without it, Renovate's annotated-dependency manager has
nothing to latch onto in `vps/` and never opens a bump PR. Keep the comment
directly above the variable and leave the value unquoted — the regex in
[`.renovaterc.json5`](../../../.renovaterc.json5) reads the token after the
colon verbatim, quotes included.

## Backup

A daily cron job (`/usr/local/bin/backup-authentik.sh`, runs at 23:40 UTC —
02:40 EEST, alongside the rest of the VPS/k8s/Nextcloud UTC-scheduled nightly
backups) dumps PostgreSQL to `/srv/backups/authentik/` with 7-day retention.
Deployed automatically by this role (re-run `make db-backups-setup` to
(re)install it).

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
