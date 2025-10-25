# Best Practices - CloudLab Merox

## Regular Maintenance Schedule

### Weekly
```bash
make check-resources    # Monitor resource usage
make health-check       # Verify all services
```

### Monthly
```bash
make update             # Update packages safely
make cleanup            # Clean unused Docker resources
```

### Quarterly
```bash
make setup --check      # Dry-run full deployment
make lint               # Check playbook syntax
```

## Before Deployment
1. **Test on single host first:**
```bash
   ansible-playbook playbooks/site.yml -l vps01 --check --ask-vault-pass
```

2. **Check current resources:**
```bash
   make check-resources
```

3. **Backup critical data:**
   - `/srv/docker/traefik/data/acme.json` (SSL certs)
   - `/srv/docker/pihole/etc-pihole/` (DNS config)
   - `/srv/docker/nextcloud/data/` (user data)

## After Deployment
1. **Run health check:**
```bash
   make health-check
```

2. **Verify all services accessible:**
   - Homepage: https://homepage.cloud.merox.dev
   - Traefik: https://traefik.cloud.merox.dev
   - Dozzle: https://dozzle.cloud.merox.dev

3. **Check logs for errors:**
```bash
   make dozzle-test
```

## Troubleshooting Common Issues

### Disk Space Full
```bash
make cleanup
make check-resources
```

### Container Not Starting
```bash
# Check logs via Dozzle or:
ansible vps_servers -m shell -a "docker logs <container_name> --tail 50" --ask-vault-pass
```

### Network Issues
```bash
# Restart Traefik
ansible vps_servers -m shell -a "docker restart traefik" --ask-vault-pass
```

### Docker Compose Version Warnings
- Already fixed: All `version:` declarations removed from docker-compose files
- These warnings are harmless but eliminated for cleaner output

## Performance Optimization

### Initial Setup Changes
- Changed from `upgrade: dist` to `upgrade: safe` for faster, safer updates
- Reduces deployment time by ~2-3 minutes
- Only installs security updates and safe upgrades

### Resource Monitoring
Watch these metrics weekly:
- **Disk usage**: Keep below 80%
- **Memory**: Monitor via Netdata
- **Container count**: Limit to essential services

## Security Checklist

### Monthly
- [ ] Rotate vault password
- [ ] Review UFW firewall rules
- [ ] Check fail2ban logs
- [ ] Update Traefik SSL certificates (auto)

### Quarterly
- [ ] Review and update secrets in vault
- [ ] Test disaster recovery procedure
- [ ] Update pinned Docker image versions

## Deployment Philosophy

### Safe Updates
- Use `make update` for routine package updates
- Use `make setup` for full infrastructure changes
- Always run `make check` before production deployment

### Idempotency
All playbooks are idempotent - running multiple times produces the same result:
```bash
make setup  # First run: applies all changes
make setup  # Second run: no changes, just verification
```

### Rollback Strategy
If deployment fails:
1. Check logs: `make health-check`
2. Review recent changes: `git log`
3. Revert to last known good state: `git checkout <commit>`
4. Re-deploy: `make setup`

## Adding New Services

Follow the established pattern:
1. Create role in `roles/<service>_setup/`
2. Add playbook in `playbooks/<service>-setup.yml`
3. Update `playbooks/site.yml`
4. Add DNS entry in `roles/pihole_setup/templates/99-ansible-custom-dns.conf.j2`
5. Add to Makefile
6. Add to Homepage dashboard
7. Test: `make <service>-test`
8. Document in README.md

## Contributing

### Before Committing
```bash
make lint               # Check syntax
make check              # Dry-run
git add .
git commit -m "feat: descriptive message"
```

### Commit Message Format
- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation only
- `refactor:` Code restructuring
- `perf:` Performance improvement

---

**Remember**: Always test on non-production first! 🚀
