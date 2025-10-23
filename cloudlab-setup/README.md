# CloudLab Merox - Ansible Infrastructure Automation

Production-ready Ansible setup for Ubuntu VPS management with Docker services stack.

## Stack Overview
- **OS**: Ubuntu 24.04 LTS hardened setup
- **Network**: Tailscale mesh VPN + exit node
- **Proxy**: Traefik with automatic HTTPS (Cloudflare DNS)
- **DNS**: Pi-hole ad-blocking DNS server
- **Management**: Portainer container orchestration
- **Deployment**: ~6 minutes for full stack

## Quick Start
```bash
# Prerequisites
sudo apt install -y python3-pip git
pip3 install ansible

# Clone & Setup
git clone <repo-url> cloudlab-merox
cd cloudlab-merox
make install

# Deploy
make ping          # Test connectivity
make setup         # Full deployment (~6 min)
```

## Daily Operations
```bash
make setup         # Full deployment (new/existing VPS)
make update        # OS package updates only
make check         # Dry-run changes preview
make docker-test   # Verify Docker stack
make traefik-test  # Check Traefik status
make pihole-test   # Verify Pi-hole DNS
make portainer-test # Check Portainer status
```

## Service Access
After deployment:
- **Traefik Dashboard**: `https://traefik.cloud.merox.dev`
- **Pi-hole Admin**: `https://pihole.cloud.merox.dev/admin`
- **Portainer**: `https://portainer.cloud.merox.dev` (set admin password on first login)
- **getHomepage dashboard**: `https://homepage.cloud.merox.dev/admin`

## Vault Management
```bash
# View/Edit secrets
make view-vault
ansible-vault edit inventories/production/group_vars/all/vault.yml

# Required secrets:
# - tailscale_auth_key
# - cloudflare_api_token
# - cloudflare_email
# - traefik_dashboard_credentials (htpasswd format)
# - pihole_webpassword
```

## Add New Server
```bash
# 1. Edit inventory
nano inventories/production/hosts
# Add: vps02 ansible_host=YOUR_IP ansible_user=root

# 2. Deploy to new host only
ansible-playbook playbooks/site.yml -l vps02 --ask-vault-pass
```

## Project Structure
```
cloudlab-merox/
├── inventories/production/
│   ├── hosts                           # Server inventory
│   └── group_vars/all/vault.yml        # Encrypted secrets
├── roles/
│   ├── initial_setup/                  # OS hardening
│   ├── docker_setup/                   # Docker installation
│   ├── tailscale_exit_node/            # VPN mesh
│   ├── pihole_prereqs/                 # DNS prerequisites
│   ├── traefik_setup/                  # Reverse proxy
│   ├── pihole_setup/                   # DNS server
│   └── portainer_setup/                # Container UI
└── playbooks/
    ├── site.yml                        # Main playbook
    ├── traefik-setup.yml               # Traefik only
    ├── pihole-setup.yml                # Pi-hole only
    └── portainer-setup.yml             # Portainer only
```

## Long-term Maintenance

### Monthly Tasks
```bash
# Update packages across all servers
make update

# Review and rotate secrets
ansible-vault edit inventories/production/group_vars/all/vault.yml
```

### Quarterly Tasks
```bash
# Update Ansible collections
make install

# Review and update pinned versions in defaults/main.yml:
# - traefik_image: "traefik:vX.Y"
# - pihole_image: "pihole/pihole:vX.Y"
# - portainer_image: "portainer/portainer-ee:X.Y.Z"

# Test on staging/single host first
ansible-playbook playbooks/site.yml -l cloudlab1 --ask-vault-pass --check
```

### Backup Strategy
```bash
# Critical paths to backup (per host):
/srv/docker/traefik/data/acme.json      # SSL certificates
/srv/docker/pihole/etc-pihole/          # Pi-hole config + custom DNS
/srv/docker/portainer/data/             # Portainer settings
/srv/docker/homepage/                   # getHomepage settings

# Automated backup role (TODO):
# - Backup to S3/Backblaze B2
# - Retention: 30 days
```

### Security Updates
```bash
# Emergency patch deployment
ansible vps_servers -m apt -a "upgrade=dist update_cache=yes" --become --ask-vault-pass

# Reboot if needed
ansible vps_servers -m reboot --become --ask-vault-pass
```

### Monitoring Checklist
- [ ] Traefik certificate renewals (auto, check logs)
- [ ] Pi-hole upstream DNS responsiveness
- [ ] Docker container health status
- [ ] Tailscale connectivity across mesh
- [ ] Disk space on `/srv/docker/` volumes

### Version Pinning Philosophy
- Pin major versions only (`traefik:v3` not `traefik:v3.2.1`)
- Update quarterly with testing
- Document breaking changes in `CHANGELOG.md`

### Disaster Recovery
```bash
# VPS rebuild (same IP)
make setup

# VPS rebuild (new IP)
# 1. Update inventories/production/hosts
# 2. Update DNS A records for *.cloud.merox.dev
# 3. make setup
# 4. Restore backups to /srv/docker/
# 5. Set Portainer admin password in UI
```

## Advanced Usage
```bash
# Run specific roles only
ansible-playbook playbooks/site.yml --tags docker --ask-vault-pass

# Skip specific roles
ansible-playbook playbooks/site.yml --skip-tags tailscale --ask-vault-pass

# Verbose debugging
ansible-playbook playbooks/site.yml -vvv --ask-vault-pass

# Dry-run with diff
ansible-playbook playbooks/site.yml --check --diff --ask-vault-pass
```

## Troubleshooting

**Port 53 conflict**
```bash
ansible vps_servers -m systemd -a "name=systemd-resolved state=stopped enabled=no" --become --ask-vault-pass
```

**Traefik certificate issues**
```bash
ansible vps_servers -m shell -a "docker logs traefik | grep -i error" --ask-vault-pass
```

**Pi-hole DNS not resolving**
```bash
# Check dnsmasq config is enabled
ansible vps_servers -m shell -a "docker exec pihole cat /etc/pihole/pihole.toml | grep etc_dnsmasq_d" --ask-vault-pass
```

**Portainer not accessible**
```bash
# Check container status
ansible vps_servers -m shell -a "docker ps | grep portainer && docker logs portainer --tail 30" --ask-vault-pass
```

**Docker network conflicts**
```bash
ansible vps_servers -m shell -a "docker network prune -f" --become --ask-vault-pass
```

## Contributing
1. Fork repository
2. Create feature branch: `git checkout -b feature/new-service`
3. Test on single host: `ansible-playbook playbooks/site.yml -l cloudlab1 --check`
4. Commit with conventional commits: `feat: add monitoring role`
5. Submit PR with test results

## Security Notes
- Vault password: Store in password manager, never commit
- Rotate secrets quarterly
- Use SSH keys only (no password auth)
- Fail2ban enabled by `initial_setup` role
- UFW firewall: Allow 22, 53, 80, 443, Tailscale
- Portainer: Set strong admin password on first login

---

**Deployment Time**: 6 minutes | **Idempotent**: Yes | **Tested**: Ubuntu 24.04 LTS
