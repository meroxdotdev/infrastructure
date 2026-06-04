.PHONY: help install ping setup quick update check facts lint \
        traefik-setup traefik-test pihole-setup pihole-test \
        portainer-setup portainer-test homepage-setup homepage-test \
        garage-setup garage-test joplin-setup joplin-test \
        uptime-kuma-setup uptime-kuma-test guacamole-setup guacamole-test \
        glances-setup glances-test netdata-setup netdata-test \
        beszel-setup beszel-test dozzle-setup dozzle-test \
        authentik-setup authentik-test authentik-backup \
        cleanup check-resources health-check \
        terraform-init terraform-plan terraform-apply terraform-destroy dr-full \
        vault-edit vault-show-required view-vault

help:
	@echo "CloudLab VPS Management"
	@echo "========================"
	@echo ""
	@echo "Disaster Recovery:"
	@echo "  dr-full            Provision Hetzner + full deploy (~15 min)"
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
	@echo "  traefik-setup      pihole-setup       portainer-setup"
	@echo "  homepage-setup     garage-setup       joplin-setup"
	@echo "  uptime-kuma-setup  guacamole-setup    glances-setup"
	@echo "  netdata-setup      beszel-setup       dozzle-setup"
	@echo "  authentik-setup"
	@echo ""
	@echo "Authentik SSO:"
	@echo "  authentik-setup    Deploy Authentik (sso.merox.dev)"
	@echo "  authentik-test     Check Authentik containers"
	@echo "  authentik-backup   Backup Authentik DB to /srv/backups/authentik/"
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

quick:
	ansible-playbook playbooks/quick-setup.yml

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

pihole-setup:
	ansible-playbook playbooks/pihole-setup.yml

pihole-test:
	ansible vps_servers -m shell -a "docker ps | grep pihole && dig @localhost google.com +short"

portainer-setup:
	ansible-playbook playbooks/portainer-setup.yml

portainer-test:
	ansible vps_servers -m shell -a "docker ps | grep portainer && curl -I http://localhost:9000"

homepage-setup:
	ansible-playbook playbooks/homepage-setup.yml

homepage-test:
	ansible vps_servers -m shell -a "docker ps | grep homepage && curl -I http://localhost:3000"

garage-setup:
	ansible-playbook playbooks/garage-setup.yml

garage-test:
	ansible vps_servers -m shell -a "docker ps | grep -E 'garage|garage-webui' && docker exec garage /garage status"

joplin-setup:
	ansible-playbook playbooks/site.yml --tags joplin

joplin-test:
	ansible vps_servers -m shell -a "docker ps | grep -E 'joplin'"

uptime-kuma-setup:
	ansible-playbook playbooks/site.yml --tags uptime-kuma

uptime-kuma-test:
	ansible vps_servers -m shell -a "docker ps | grep uptime-kuma"

guacamole-setup:
	ansible-playbook playbooks/site.yml --tags guacamole

guacamole-test:
	ansible vps_servers -m shell -a "docker ps | grep guacamole"

glances-setup:
	ansible-playbook playbooks/site.yml --tags glances

glances-test:
	ansible vps_servers -m shell -a "docker ps | grep glances"

netdata-setup:
	ansible-playbook playbooks/netdata-setup.yml

netdata-test:
	ansible vps_servers -m shell -a "docker ps | grep netdata && curl -I http://localhost:19999"

beszel-setup:
	ansible-playbook playbooks/beszel-setup.yml

beszel-test:
	ansible vps_servers -m shell -a "docker ps | grep beszel"

dozzle-setup:
	ansible-playbook playbooks/dozzle-setup.yml

dozzle-test:
	ansible vps_servers -m shell -a "docker ps | grep dozzle"

# --- Authentik SSO ---
authentik-setup:
	ansible-playbook playbooks/authentik-setup.yml

authentik-test:
	ansible vps_servers -m shell -a "docker ps | grep -E 'authentik'"

authentik-backup:
	ansible-playbook playbooks/authentik-backup.yml

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
	if [ -n "$$NEW_IP" ]; then \
		sed -i "s/^vps01 .*/vps01 ansible_host=$$NEW_IP/" inventories/production/hosts; \
		echo "Server IP: $$NEW_IP — inventory updated (ansible_connection=local removed for SSH)"; \
		echo "Run: make setup  (after ~30s for cloud-init)"; \
	fi

terraform-destroy:
	@echo "WARNING: This will destroy the server. Press Ctrl+C to cancel."
	@sleep 5
	cd terraform && terraform destroy

dr-full:
	@echo "Starting full disaster recovery..."
	$(MAKE) terraform-apply
	@echo "Waiting 45s for server boot + cloud-init..."
	@sleep 45
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
	@echo "  # Tailscale — HAS vault_ prefix"
	@echo "  vault_tailscale_auth_key:      '<from tailscale admin panel>'"
	@echo ""
	@echo "  # Pi-hole — no vault_ prefix"
	@echo "  pihole_webpassword:            '<strong password>'"
	@echo ""
	@echo "  # Joplin — HAS vault_ prefix"
	@echo "  vault_joplin_db_password:      '<openssl rand -base64 32>'"
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
	@echo "  docker exec joplin-db env | grep POSTGRES_PASSWORD"
	@echo ""
	@echo "Edit: make vault-edit"
