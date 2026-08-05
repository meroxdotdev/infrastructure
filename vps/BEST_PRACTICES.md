# Best Practices

## Production checkout (on the VPS itself)

`ansible_connection=local` means deploys run *from the VPS*, not from your
laptop — there's a working clone at `/srv/kubernetes/infrastructure` on the
server (name is historical, not a k8s thing). It doesn't auto-update:

```bash
cd /srv/kubernetes/infrastructure && git pull   # before any make setup
```

Never set `credential.helper=store` there (or anywhere on that checkout).
The repo is public, so `git pull`/`fetch` need no credentials at all — the
helper only exists to *persist* a token the moment one is ever typed for a
push, in plaintext, granting standing write access to anyone with root on
the VPS from then on. If a future re-clone re-enables it (some OS images
set a global default), unset it:

```bash
git config --global --unset credential.helper
```

## Maintenance

**Weekly**
```bash
make check-resources   # disk/memory/CPU
make health-check      # verify all services
```

**Monthly**
```bash
make update            # OS package updates (safe, not dist-upgrade)
make cleanup           # remove unused Docker images/volumes
make authentik-backup  # manual Authentik DB backup
```

## Before deploying

Always dry-run first:
```bash
make check   # no changes applied, shows what would change
make ping    # verify connectivity
```

## Idempotency

All playbooks are idempotent — safe to re-run at any time:
```bash
make setup   # first run: applies changes; subsequent runs: verifies state
```

## Adding a new service

1. Create `roles/<service>_setup/` with `defaults/`, `tasks/`, `handlers/`, `templates/`, `meta/`
2. Add `playbooks/<service>-setup.yml`
3. Add role to `playbooks/site.yml` in correct order (Traefik must come before all services)
4. Add `<service>-setup` and `<service>-test` targets to `Makefile`
5. Update `README.md` Stack table
6. Pick a free static IP from `172.25.10.x` (see allocation below)

## Static IP allocation (network-cloud-merox / 172.25.0.0/16)

| IP | Container |
|----|-----------|
| .2 | traefik |
| .10 | homepage |
| .11 | homepage-public |
| .12 | homelab-stats-server |
| .20 | free (was glances, not carried over in the 2026-07-26 app-stack migration) |
| .30 | portainer |
| .33 | guacamole |
| .40 | free (was code-server, decommissioned) |
| .50 | free (was uptime-kuma, decommissioned) |
| .51 | free (was dozzle, not carried over in the 2026-07-26 app-stack migration) |
| .52 | unbound |
| .53 | pihole |
| .60 | joplin-db |
| .61 | joplin-server |
| .62-64 | free (reserved for nextcloud, never deployed) |
| .70 | authentik-postgresql |
| .71 | authentik-redis |
| .72 | authentik-server |
| .73 | authentik-worker |
| .74+ | free |

## Secrets

- All secrets in `inventories/production/group_vars/all/vault.yml` (AES256)
- Vault password in `.vault_pass` (gitignored — never commit)
- `ansible.cfg` reads `.vault_pass` automatically — no manual password prompt needed
- See required variables: `make vault-show-required`

## Rollback

```bash
git log --oneline        # find last good commit
git checkout <commit>    # revert files
make setup               # re-deploy
```

## Code conventions

- `become: true` (not `become: yes`)
- Variable naming: `<service>_container_ip` for static Docker IPs
- Handler naming: `Restart <service>` or `Reload <service>`
- All role defaults in `defaults/main.yml`, secrets in vault only
- No hardcoded paths in tasks — use variables (`{{ traefik_docker_dir }}` not `/srv/docker/traefik`)
- `README.md` only for roles with non-obvious behavior (external dependencies,
  manual provisioning steps, gotchas — see `vps_backup`, `authentik_setup`).
  Simple deploy-a-container roles don't need one.
