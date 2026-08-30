# vps/ — Oracle Cloud (Ansible + Terraform)

Ansible roles + Terraform for two Oracle hosts. Part of the
[meroxdotdev/infrastructure](https://github.com/meroxdotdev/infrastructure)
repo — rebuild guide in [DEPLOY.md](../DEPLOY.md), service index in the
[main README](../README.md).

| Host | Playbook | What it is |
|---|---|---|
| `vps01`, us-phoenix-1 | `site.yml` → `make setup` | The off-site stack. Everything behind the Cloudflare tunnel, no open inbound ports |
| `edge-fra`, eu-frankfurt-1 | `edge.yml` → `make edge-setup` | Public TLS edge for Jellyfin only. Stateless, borrowed tenancy, [design](../docs/jellyfin-public-exposure.md) |

Three deployment modes:

- **vps01 (production):** Ansible runs *on the server itself*
  (`ansible_connection=local` — OCI blocks inbound SSH from arbitrary IPs).
- **edge-fra:** over SSH from any machine on the tailnet. Tailscale is
  outbound, so OCI's inbound rules do not apply.
- **DR (Hetzner fallback):** `make dr-full` from any machine — Terraform
  provisions the server, then Ansible deploys over SSH. ~15 min.

## Stack

Traefik (reverse proxy + ACME), Pi-hole + Unbound, Authentik SSO, Portainer EE,
Homepage, Joplin Server + Postgres, Guacamole — one role per service under
`roles/`, full URL table in the [main README](../README.md#everything-at-a-glance).
All web traffic goes through Cloudflare Tunnel — no open inbound ports.
Its hostname routing table lives in the Cloudflare dashboard, not git — see
[roles/cloudflared_setup/README.md](roles/cloudflared_setup/README.md).

Garage S3 doesn't run on this VPS at all — it's an independent LXC on R730xd
(`garage-setup-r730xd.yml`, see
[proxmox/r730xd/README.md](../proxmox/r730xd/README.md#garage-longhorns-backup-target)),
untouched by anything in this directory. See
[DR.md](../DR.md#r730xd--garage-total-loss-fallback) for its own recovery path.

The root `docker-compose.yml` + Homepage config (`config/`) used to live in a
separate repo (`meroxdotdev/cloudlab-merox`, retired 2026-07-25) — now under
`roles/app_stack_setup/files/app-stack/`, deployed like every other service.

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
make dr-restore         # DR: restore all data from NAS (non-interactive)

make <service>-setup    # individual service, e.g. make authentik-setup
make help               # everything else
```

edge-fra:

```bash
make edge-ping          # verify connectivity over the tailnet
make edge-setup         # full deploy (~6 min, idempotent)
make edge-check         # dry-run
make edge-verify        # firewall, geoblock, cert, backend, isolation checks
```

## Disaster recovery

`make dr-full` from your local machine: Terraform provisions the Hetzner VPS,
updates the inventory with the new IP (and drops `ansible_connection=local`),
waits for cloud-init, then runs the full deploy. Cloudflare Tunnel, Tailscale
and Let's Encrypt reconnect automatically with the existing tokens. Afterwards
restore data from R730xd: `make dr-restore` runs the full restore sequence
(pull from R730xd, DB restore, extras restore) non-interactively — see
[DEPLOY.md Phase 1](../DEPLOY.md) and [roles/vps_backup/README.md](roles/vps_backup/README.md).

## Conventions & layout

Role layout, static IP allocation (`172.25.10.x`), secrets handling and code
conventions: [BEST_PRACTICES.md](BEST_PRACTICES.md). Secrets live in
`inventories/production/group_vars/all/vault.yml` (AES256); `ansible.cfg` reads
`.vault_pass` automatically.
