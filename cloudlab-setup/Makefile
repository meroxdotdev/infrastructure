.PHONY: help install ping setup quick update check facts lint traefik-setup traefik-test pihole-setup pihole-test portainer-setup portainer-test homepage-setup homepage-test cleanup check-resources health-check

help:
	@echo "Ansible VPS Management Commands"
	@echo "================================"
	@echo "install          - Install required collections"
	@echo "ping             - Test connectivity"
	@echo "setup            - Full setup (all services)"
	@echo "quick            - Quick recovery setup"
	@echo "update           - Update all packages"
	@echo "check            - Dry-run setup playbook"
	@echo "facts            - Gather system facts"
	@echo "lint             - Lint all playbooks"
	@echo ""
	@echo "Infrastructure:"
	@echo "docker-setup     - Install Docker only"
	@echo "docker-test      - Test Docker installation"
	@echo "traefik-setup    - Deploy Traefik reverse proxy"
	@echo "traefik-test     - Test Traefik deployment"
	@echo "pihole-setup     - Deploy Pi-hole DNS server"
	@echo "pihole-test      - Test Pi-hole deployment"
	@echo "portainer-setup  - Deploy Portainer container UI"
	@echo "portainer-test   - Test Portainer deployment"
	@echo "homepage-setup   - Deploy Homepage dashboard"
	@echo "homepage-test    - Test Homepage deployment"
	@echo "netdata-setup    - Deploy Netdata monitoring"
	@echo "netdata-test     - Test Netdata deployment"
	@echo "beszel-setup     - Deploy Beszel monitoring"
	@echo "beszel-test      - Test Beszel deployment"
	@echo "dozzle-setup     - Deploy Dozzle log viewer"
	@echo "dozzle-test      - Test Dozzle deployment"
	@echo "nextcloud-setup  - Deploy Nextcloud storage"
	@echo "nextcloud-test   - Test Nextcloud deployment"
	@echo ""
	@echo "Maintenance:"
	@echo "cleanup          - Remove unused Docker resources"
	@echo "check-resources  - Display VPS resource usage"
	@echo "health-check     - Post-deployment health check"
	@echo ""
	@echo "Utilities:"
	@echo "view-vault       - View encrypted vault file"

install:
	ansible-galaxy collection install -r requirements.yml

ping:
	ansible vps_servers -m ping --ask-vault-pass

setup:
	ansible-playbook playbooks/site.yml --ask-vault-pass

quick:
	ansible-playbook playbooks/quick-setup.yml --ask-vault-pass

update:
	ansible-playbook playbooks/update.yml --ask-vault-pass

check:
	ansible-playbook playbooks/site.yml --check --diff --ask-vault-pass

facts:
	ansible vps_servers -m setup --ask-vault-pass

lint:
	@command -v ansible-lint >/dev/null 2>&1 && ansible-lint playbooks/*.yml || echo "ansible-lint not installed. Run: pip install ansible-lint"

# Infrastructure commands
docker-setup:
	ansible-playbook playbooks/docker-setup.yml --ask-vault-pass

docker-test:
	ansible vps_servers -m shell -a "docker ps && docker compose version" --ask-vault-pass

traefik-setup:
	ansible-playbook playbooks/traefik-setup.yml --ask-vault-pass

traefik-test:
	ansible vps_servers -m shell -a "docker ps | grep traefik && docker logs traefik --tail 20" --ask-vault-pass

pihole-setup:
	ansible-playbook playbooks/pihole-setup.yml --ask-vault-pass

pihole-test:
	ansible vps_servers -m shell -a "docker ps | grep pihole && dig @localhost google.com +short" --ask-vault-pass

portainer-setup:
	ansible-playbook playbooks/portainer-setup.yml --ask-vault-pass

portainer-test:
	ansible vps_servers -m shell -a "docker ps | grep portainer && curl -I http://localhost:9000" --ask-vault-pass

homepage-setup:
	ansible-playbook playbooks/homepage-setup.yml --ask-vault-pass

homepage-test:
	ansible vps_servers -m shell -a "docker ps | grep homepage && curl -I http://localhost:3000" --ask-vault-pass

netdata-setup:
	ansible-playbook playbooks/netdata-setup.yml --ask-vault-pass

netdata-test:
	ansible vps_servers -m shell -a "docker ps | grep netdata && curl -I http://localhost:19999" --ask-vault-pass

beszel-setup:
	ansible-playbook playbooks/beszel-setup.yml --ask-vault-pass

beszel-test:
	ansible vps_servers -m shell -a "docker ps | grep beszel" --ask-vault-pass

dozzle-setup:
	ansible-playbook playbooks/dozzle-setup.yml --ask-vault-pass

dozzle-test:
	ansible vps_servers -m shell -a "docker ps | grep dozzle" --ask-vault-pass

nextcloud-setup:
	ansible-playbook playbooks/nextcloud-setup.yml --ask-vault-pass

nextcloud-test:
	ansible vps_servers -m shell -a "docker ps | grep nextcloud" --ask-vault-pass

# Maintenance commands
cleanup:
	ansible-playbook playbooks/cleanup.yml --ask-vault-pass

check-resources:
	ansible-playbook playbooks/check-resources.yml --ask-vault-pass

health-check:
	ansible-playbook playbooks/health-check.yml --ask-vault-pass

# View encrypted files
view-vault:
	ansible-vault view inventories/production/group_vars/all/vault.yml
