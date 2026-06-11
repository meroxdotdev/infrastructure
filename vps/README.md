# vps/ — Oracle Cloud VPS (Ansible + Terraform)

Ansible roles + Terraform for the Docker stack on the Oracle Cloud Free Tier VPS.
Part of the [meroxdotdev/infrastructure](https://github.com/meroxdotdev/infrastructure)
repo — full rebuild guide in [DEPLOY.md](../DEPLOY.md), service index in the
[main README](../README.md).

Two deployment modes:

- **Production (Oracle Cloud):** Ansible runs *on the server itself*
  (`ansible_connection=local` in the inventory — OCI blocks inbound SSH from
  arbitrary IPs).
- **DR (Hetzner fallback):** `make dr-full` from any machine — Terraform
  provisions the server, then Ansible deploys over SSH. ~15 min.

## Stack

Traefik (reverse proxy + ACME), Pi-hole + Unbound, Authentik SSO, Portainer EE,
Homepage, Joplin Server + Postgres, Uptime Kuma, Guacamole, Garage S3, Netdata,
Beszel, Dozzle, Glances — one role per service under `roles/`, full URL table in
the [main README](../README.md#everything-at-a-glance). All web traffic goes
through Cloudflare Tunnel — no open inbound ports.

## Setup on a fresh machine

```bash
git clone https://github.com/meroxdotdev/infrastructure
cd infrastructure/vps
make install                                  # Ansible Galaxy collections
echo "<vault-password>" > .vault_pass && chmod 600 .vault_pass
make vault-show-required                      # lists required vault variables
make vault-edit                               # fill them in
# DR only: cp terraform/terraform.tfvars.example terraform/terraform.tfvars
#          (hcloud_token, ssh key path) + make terraform-init
```

## Common commands

```bash
make ping               # verify connectivity
make check              # dry-run (--check --diff)
make setup              # full deploy (~12 min, idempotent)
make update             # OS package updates only
make health-check       # verify all services
make cleanup            # prune unused Docker images/volumes
make restore            # interactive DB restore wizard (Authentik / Joplin)
make backup-sync-now    # run extras backup + NAS sync immediately
make dr-full            # provision Hetzner fallback + deploy everything

make <service>-setup    # individual service, e.g. make authentik-setup
make help               # everything else
```

## Disaster recovery

`make dr-full` from your local machine: Terraform provisions the Hetzner VPS,
updates the inventory with the new IP (and drops `ansible_connection=local`),
waits for cloud-init, then runs the full deploy. Cloudflare Tunnel, Tailscale
and Let's Encrypt reconnect automatically with the existing tokens. Afterwards
restore data from the NAS: `make restore` (DBs) + untar service state — see
[DEPLOY.md Phase 1](../DEPLOY.md) and [roles/vps_backup/README.md](roles/vps_backup/README.md).

## Conventions & layout

Role layout, static IP allocation (`172.25.10.x`), secrets handling and code
conventions: [BEST_PRACTICES.md](BEST_PRACTICES.md). Secrets live in
`inventories/production/group_vars/all/vault.yml` (AES256); `ansible.cfg` reads
`.vault_pass` automatically.
