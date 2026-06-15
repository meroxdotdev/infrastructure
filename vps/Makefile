.PHONY: help install ping setup update check facts lint \
        traefik-setup traefik-test \
        garage-setup garage-test \
        uptime-kuma-setup uptime-kuma-test guacamole-setup guacamole-test \
        netdata-setup netdata-test \
        authentik-setup authentik-test authentik-backup \
        cleanup check-resources health-check \
        terraform-init terraform-plan terraform-apply terraform-destroy dr-full dr-preflight \
        dr-verify-phase1 dr-verify-phase2 dr-verify-phase3 garage-extract-creds \
        restore-pull-nas restore-extras restore-auto dr-restore \
        vault-edit vault-show-required view-vault

help:
	@echo "CloudLab VPS Management"
	@echo "========================"
	@echo ""
	@echo "Disaster Recovery:"
	@echo "  dr-preflight       Pre-flight checks before dr-full"
	@echo "  dr-full            Pre-flight + provision Hetzner + full deploy (~15 min)"
	@echo "  dr-verify-phase1   Verify VPS phase (run on the VPS)"
	@echo "  dr-verify-phase2   Verify K8s phase (run from local machine)"
	@echo "  dr-verify-phase3   Verify Agents phase (run on the VPS)"
	@echo "  dr-restore         DR: restore all data from NAS (pull + DB + extras, non-interactive)"
	@echo "  garage-extract-creds  Extract Garage S3 creds + update vault (between Phase 1+2)"
	@echo "  terraform-apply    Provision server on Hetzner only"
	@echo "  terraform-plan     Preview what Terraform will create"
	@echo "  terraform-init     Initialize Terraform (first time only)"
	@echo ""
	@echo "Full deploy:"
	@echo "  setup              Deploy all services"
	@echo "  check              Dry-run (no changes applied)"
	@echo "  ping               Test connectivity to server"
	@echo "  update             OS package updates only"
	@echo "  health-check       Post-deploy verification"
	@echo ""
	@echo "Individual services:"
	@echo "  traefik-setup      garage-setup       uptime-kuma-setup"
	@echo "  guacamole-setup    netdata-setup      authentik-setup"
	@echo ""
	@echo "Authentik SSO:"
	@echo "  authentik-setup    Deploy Authentik (sso.merox.dev)"
	@echo "  authentik-test     Check Authentik containers"
	@echo "  authentik-backup   Backup Authentik DB to /srv/backups/authentik/"
	@echo ""
	@echo "Backups:"
	@echo "  db-backups-setup   Deploy backup scripts + crons (DB dumps, extras, NAS sync)"
	@echo "  backup-sync-now    Run extras backup + NAS sync immediately"
	@echo "  restore-pull-nas   DR: pull NAS backup copies back to /srv/backups + garage"
	@echo "  restore            Restore Authentik + Joplin DBs from latest dump (interactive)"
	@echo "  restore-auto       DR: restore Authentik + Joplin DBs from latest dump (non-interactive)"
	@echo "  restore-extras     DR: restore Guacamole/Traefik/Pi-hole/Homepage/Portainer/etc from /srv/backups (non-interactive)"
	@echo ""
	@echo "Vault:"
	@echo "  vault-edit         Edit encrypted secrets"
	@echo "  vault-show-required  Show all required vault variables"
	@echo "  view-vault         View vault contents"
	@echo ""
	@echo "Maintenance:"
	@echo "  cleanup            Remove unused Docker resources"
	@echo "  check-resources    Monitor disk/memory/CPU"
	@echo "  lint               Check playbook syntax"

# --- Setup ---
install:
	ansible-galaxy collection install -r requirements.yml

ping:
	ansible vps_servers -m ping

setup:
	ansible-playbook playbooks/site.yml

update:
	ansible-playbook playbooks/update.yml

check:
	ansible-playbook playbooks/site.yml --check --diff

facts:
	ansible vps_servers -m setup

lint:
	@command -v ansible-lint >/dev/null 2>&1 \
		&& ansible-lint playbooks/*.yml \
		|| echo "ansible-lint not installed — run: pip install ansible-lint"

# --- Infrastructure ---
docker-setup:
	ansible-playbook playbooks/docker-setup.yml

docker-test:
	ansible vps_servers -m shell -a "docker ps && docker compose version"

traefik-setup:
	ansible-playbook playbooks/traefik-setup.yml

traefik-test:
	ansible vps_servers -m shell -a "docker ps | grep traefik && docker logs traefik --tail 20"

garage-setup:
	ansible-playbook playbooks/garage-setup.yml

garage-test:
	ansible vps_servers -m shell -a "docker ps | grep -E 'garage|garage-webui' && docker exec garage /garage status"

uptime-kuma-setup:
	ansible-playbook playbooks/site.yml --tags uptime-kuma

uptime-kuma-test:
	ansible vps_servers -m shell -a "docker ps | grep uptime-kuma"

guacamole-setup:
	ansible-playbook playbooks/site.yml --tags guacamole

guacamole-test:
	ansible vps_servers -m shell -a "docker ps | grep guacamole"

netdata-setup:
	ansible-playbook playbooks/netdata-setup.yml

netdata-test:
	ansible vps_servers -m shell -a "docker ps | grep netdata && curl -I http://localhost:19999"

# --- Authentik SSO ---
authentik-setup:
	ansible-playbook playbooks/authentik-setup.yml

authentik-test:
	ansible vps_servers -m shell -a "docker ps | grep -E 'authentik'"

authentik-backup:
	ansible-playbook playbooks/authentik-backup.yml

# --- Backups (DB dumps + VPS extras + nightly NAS sync) ---
db-backups-setup:
	ansible-playbook playbooks/authentik-setup.yml --tags backup
	ansible-playbook playbooks/site.yml --tags backup

backup-sync-now:
	/usr/local/bin/backup-vps-extras.sh && /usr/local/bin/backup-push-nas.sh

restore:
	/usr/local/bin/restore-db.sh all

restore-authentik:
	/usr/local/bin/restore-db.sh authentik

restore-joplin:
	/usr/local/bin/restore-db.sh joplin

restore-pull-nas:
	/usr/local/bin/restore-pull-from-nas.sh

restore-auto:
	/usr/local/bin/restore-db.sh --yes all

restore-extras:
	/usr/local/bin/restore-extras.sh

dr-restore:
	ansible-playbook playbooks/dr-restore.yml

# --- Maintenance ---
cleanup:
	ansible-playbook playbooks/cleanup.yml

check-resources:
	ansible-playbook playbooks/check-resources.yml

health-check:
	ansible-playbook playbooks/health-check.yml

# --- Terraform / Disaster Recovery ---
terraform-init:
	cd terraform && terraform init

terraform-plan:
	cd terraform && terraform plan

terraform-apply:
	cd terraform && terraform apply -auto-approve
	@NEW_IP=$$(cd terraform && terraform output -raw server_ip 2>/dev/null); \
	SSH_KEY=$$(grep ssh_public_key_path terraform/terraform.tfvars | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | sed 's/\.pub//' | tr -d ' '); \
	if [ -n "$$NEW_IP" ]; then \
		sed "s|^vps01 .*|vps01 ansible_host=$$NEW_IP ansible_ssh_private_key_file=$$SSH_KEY|" inventories/production/hosts > inventories/production/hosts.tmp && mv inventories/production/hosts.tmp inventories/production/hosts; \
		echo "Server IP: $$NEW_IP — inventory updated (SSH key: $$SSH_KEY)"; \
		echo "Run: make setup  (after ~30s for cloud-init)"; \
	fi

terraform-destroy:
	@echo "WARNING: This will destroy the server. Press Ctrl+C to cancel."
	@sleep 5
	cd terraform && terraform destroy

dr-preflight:
	@bash ../scripts/dr-preflight.sh

dr-verify-phase1:
	@bash ../scripts/dr-verify.sh --phase 1

dr-verify-phase2:
	@bash ../scripts/dr-verify.sh --phase 2

dr-verify-phase3:
	@bash ../scripts/dr-verify.sh --phase 3

garage-extract-creds:
	@bash ../scripts/garage-extract-creds.sh

dr-full:
	@echo "Starting full disaster recovery..."
	$(MAKE) dr-preflight
	$(MAKE) terraform-apply
	@echo "Polling for SSH availability (max 300s)..."
	@NEW_IP=$$(cd terraform && terraform output -raw server_ip 2>/dev/null); \
	ssh-keygen -R $$NEW_IP 2>/dev/null || true; \
	for i in $$(seq 1 60); do \
	  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
	    -i ~/.ssh/cloudlab_dr_test root@$$NEW_IP exit 2>/dev/null \
	    && echo "  Server ready after $$((i * 5))s." && break; \
	  [ $$i -eq 60 ] && echo "ERROR: server unreachable after 300s" && exit 1; \
	  echo "  Attempt $$i/60 — waiting 5s..."; \
	  sleep 5; \
	done
	$(MAKE) setup

# --- Vault ---
vault-edit:
	ansible-vault edit inventories/production/group_vars/all/vault.yml

view-vault:
	ansible-vault view inventories/production/group_vars/all/vault.yml

vault-show-required:
	@echo "Required vault variables (make vault-edit):"
	@echo "NOTE: most keys have NO vault_ prefix — use exact names below"
	@echo ""
	@echo "  # Cloudflare — no vault_ prefix"
	@echo "  cloudflare_api_token:          '<from cloudflare dashboard>'"
	@echo "  cloudflare_email:              '<your cloudflare email>'"
	@echo "  traefik_dashboard_credentials: '<htpasswd -nb user pass>'"
	@echo ""
	@echo "  # Cloudflare Tunnel connector (cloudflared) — no vault_ prefix"
	@echo "  cloudflare_tunnel_token:       '<Zero Trust > Networks > Tunnels > one > Configure>'"
	@echo "                                  NOTE: this is the connector token (eyJ...), NOT"
	@echo "                                  homepage_cloudflare_token (that's an API token"
	@echo "                                  used only by the Homepage Cloudflared widget)."
	@echo ""
	@echo "  # Tailscale — HAS vault_ prefix"
	@echo "  vault_tailscale_auth_key:      '<from tailscale admin panel>'"
	@echo ""
	@echo "  # Pi-hole — no vault_ prefix"
	@echo "  pihole_webpassword:            '<strong password>'"
	@echo ""
	@echo "  # Garage S3 — no vault_ prefix"
	@echo "  garage_rpc_secret:             '<openssl rand -hex 32>'"
	@echo "  garage_admin_token:            '<openssl rand -hex 32>'"
	@echo ""
	@echo "  # Authentik SSO — no vault_ prefix, note key names"
	@echo "  authentik_pg_pass:             '<openssl rand -base64 36>'"
	@echo "  authentik_secret_key:          '<openssl rand -base64 60>'"
	@echo ""
	@echo "Recover from live server (before it disappears):"
	@echo "  docker exec authentik-postgresql env | grep POSTGRES_PASSWORD"
	@echo "  docker exec authentik-server env | grep SECRET_KEY"
	@echo ""
	@echo "Edit: make vault-edit"
