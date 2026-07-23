# Best Practices

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
| .20 | glances |
| .30 | portainer |
| .33 | guacamole |
| .40 | code-server |
| .50 | free (was uptime-kuma, decommissioned) |
| .51 | dozzle |
| .53 | pihole |
| .60 | joplin-db |
| .61 | joplin-server |
| .62 | nextcloud-redis |
| .63 | nextcloud |
| .64 | nextcloud-db |
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
