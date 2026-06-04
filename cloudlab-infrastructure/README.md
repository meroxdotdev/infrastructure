# cloudlab-merox

Ansible + Terraform infrastructure-as-code for a self-hosted Docker stack on Oracle Cloud Free Tier. Full disaster recovery in ~15 minutes.

---

## Stack

| Service | Purpose | URL |
|---|---|---|
| Traefik | Reverse proxy + Let's Encrypt | traefik.cloud.merox.dev |
| Pi-hole | DNS ad-blocking | pihole.cloud.merox.dev/admin |
| Portainer EE | Container management (Tailscale only) | 100.72.22.38:9000 |
| Homepage | Dashboard | inside.merox.dev |
| Joplin Server | Notes sync (+ Postgres) | joplin.cloud.merox.dev |
| Uptime Kuma | Service monitoring | status.merox.dev |
| Guacamole | Remote desktop (Authentik SSO) | rmt.merox.dev |
| Glances | System monitoring | glances.cloud.merox.dev |
| Garage S3 | S3-compatible storage | garage.cloud.merox.dev |
| Authentik | SSO / Identity Provider | sso.merox.dev |

All services route through Cloudflare Tunnel (`one`) — no open inbound ports on Oracle Cloud.

---

## Quick start

### First time

```bash
sudo apt install -y python3-pip git
pip3 install ansible
git clone https://github.com/meroxdotdev/cloudlab-merox
cd cloudlab-merox
make install          # install Ansible Galaxy collections
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit terraform.tfvars: add hcloud_token, ssh key path
make terraform-init
```

### Vault setup

```bash
# Create vault password file (gitignored)
echo "your-vault-password" > .vault_pass
chmod 600 .vault_pass

make vault-edit       # add required secrets (see make vault-show-required)
```

Required vault variables (`make vault-show-required` prints this list):
```yaml
# Cloudflare (used directly by traefik_setup — no vault_ prefix)
cloudflare_api_token:          "<from cloudflare dashboard>"
cloudflare_email:              "<your cloudflare email>"
traefik_dashboard_credentials: "<htpasswd -nb user pass>"

# Tailscale (vault_ prefix — mapped in vars.yml)
vault_tailscale_auth_key:      "<from tailscale admin panel>"

# Pi-hole (used directly)
pihole_webpassword:            "<strong password>"

# Joplin (vault_ prefix — mapped in vars.yml)
vault_joplin_db_password:      "<openssl rand -base64 32>"

# Garage S3 (used directly)
garage_rpc_secret:             "<openssl rand -hex 32>"
garage_admin_token:            "<openssl rand -hex 32>"

# Authentik (used directly — note: pg_pass not db_password)
authentik_pg_pass:             "<openssl rand -base64 36>"
authentik_secret_key:          "<openssl rand -base64 60>"
```

### Deploy

```bash
make ping     # verify connectivity
make setup    # full deploy (~12 min)
```

---

## Disaster recovery

If the server disappears:

```bash
# Run from your LOCAL machine (not from Oracle Cloud)
make dr-full   # provisions fallback VPS (Hetzner) + deploys everything (~15 min)
```

**Prerequisites on the machine running DR:**
- Ansible + collections: `make install`
- `.vault_pass` file with your vault password
- SSH key matching `terraform.tfvars → ssh_public_key_path`
- Filled `terraform/terraform.tfvars`

**What happens automatically:**
- `terraform apply` provisions fallback VPS + updates `inventories/production/hosts` with new IP and removes `ansible_connection=local` (Oracle Cloud only flag)
- 45s wait for cloud-init
- `make setup` deploys all services over SSH

**Reconnects automatically:** Cloudflare Tunnel (same token), Tailscale (same auth key), Let's Encrypt certs (regenerated via Cloudflare DNS challenge).

**Manual after recovery:** restore Docker volume data from backup (Garage S3, Joplin DB, Authentik DB via `make authentik-backup`).

---

## Common commands

```bash
make setup              # full deploy
make check              # dry-run (no changes)
make update             # OS updates only
make health-check       # verify all services

# Individual services
make traefik-setup
make pihole-setup
make portainer-setup
make joplin-setup
make garage-setup
make authentik-setup
make authentik-backup   # backup Authentik DB

# Vault
make vault-edit
make vault-show-required

# Terraform
make terraform-plan
make terraform-apply
make terraform-destroy
```

---

## Project structure

```
cloudlab-merox/
├── terraform/                    # Fallback VPS provisioning (Hetzner)
├── inventories/production/
│   ├── hosts                     # server IP + connection mode
│   └── group_vars/all/vault.yml  # encrypted secrets
├── roles/
│   ├── initial_setup/            # OS packages, timezone, NTP
│   ├── docker_setup/             # Docker CE + compose plugin
│   ├── security_hardening/       # SSH hardening, fail2ban, sysctl
│   ├── tailscale_exit_node/      # Tailscale VPN
│   ├── pihole_prereqs/           # disable systemd-resolved
│   ├── traefik_setup/            # reverse proxy + Cloudflare ACME
│   ├── pihole_setup/             # Pi-hole DNS
│   ├── portainer_setup/          # Portainer EE
│   ├── homepage_setup/           # Homepage dashboard
│   ├── garage_setup/             # Garage S3 storage
│   ├── joplin_setup/             # Joplin Server + Postgres
│   ├── uptime_kuma_setup/        # Uptime Kuma monitoring
│   ├── guacamole_setup/          # Guacamole remote desktop
│   ├── glances_setup/            # Glances system monitoring
│   └── authentik_setup/          # Authentik SSO
└── playbooks/
    ├── site.yml                  # full deploy (all roles, correct order)
    ├── authentik-setup.yml       # Authentik only
    ├── authentik-backup.yml      # backup Authentik DB
    ├── health-check.yml          # post-deploy verification
    └── update.yml                # OS package updates
```

---

## Authentik SSO

Included in `site.yml` — deploys automatically with `make setup` and `make dr-full`.

```bash
make authentik-setup   # deploy/update Authentik only (sso.merox.dev)
make authentik-backup  # pg_dump to /srv/backups/authentik/ (7-day retention)
```

Guacamole (`rmt.merox.dev`) is protected via Authentik forward-auth through Traefik.

---

## Troubleshooting

**Port 53 conflict (systemd-resolved)**
```bash
ansible vps_servers -m systemd -a "name=systemd-resolved state=stopped enabled=no" --become
```

**Traefik certificate errors**
```bash
ansible vps_servers -m shell -a "docker logs traefik | grep -i error"
```

**Garage unreachable**
```bash
ansible vps_servers -m shell -a "docker exec garage /garage status"
```

**Authentik not starting**
```bash
ansible vps_servers -m shell -a "docker logs authentik-server --tail 50"
```

---

**Tested on:** Ubuntu 24.04 LTS (Oracle Cloud ARM) | **Deploy time:** ~12 min | **DR time:** ~15 min
