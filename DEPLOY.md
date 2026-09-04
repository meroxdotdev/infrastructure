# Deploy — full rebuild on new hardware

VPS first, then the cluster. ~35 min.

Rebuilding onto the *same* identity is [`DR.md`](DR.md) — shorter, because the
IPs and MACs stay. This page is for when they change.

## Prerequisites

| Item | Where |
|---|---|
| Vault password | Password manager |
| `age.key` | Backed up separately — **critical**, nothing recovers it |
| Tailscale reusable auth key | Tailscale admin console (they expire after 90 days) |
| Cloudflare API token | Cloudflare dashboard |
| Portainer EE license | Portainer account |
| Hetzner API token | console.hetzner.cloud → Security → API Tokens |
| DR SSH key | `~/.ssh/cloudlab_dr_test{,.pub}` — `ssh-keygen -t ed25519 -f ~/.ssh/cloudlab_dr_test -N ""` |
| R730xd push key | `vault_oracle_vps_to_r730xd_ssh_key`; public half authorised on `root@pve-2` |

`vps/terraform/terraform.tfvars` is gitignored — recreate it:

```hcl
hcloud_token        = "<hetzner-api-token>"
ssh_public_key_path = "~/.ssh/cloudlab_dr_test.pub"
server_name         = "cloudlab-vps"
server_type         = "cx33"                  # cax21/ARM untested
server_location     = "nbg1"
allowed_ips         = ["<your-home-ip>/32"]   # never 0.0.0.0/0
```

## Phase 1 — VPS (~15 min)

Deploys SSH hardening, fail2ban, Docker, Tailscale, Traefik, Cloudflare Tunnel,
Pi-hole + Unbound, Portainer, Homepage, Joplin, Guacamole, Authentik.

Check the Tailscale key first — a stale one fails halfway through:

```bash
cd vps/
make vault-edit          # vault_tailscale_auth_key
make terraform-init      # first time only
make dr-full             # preflight + terraform + Ansible
make dr-restore          # pulls service data back from pve-2
```

Terraform provisions the server; Ansible runs from your machine over SSH.
Production on Oracle differs — there Ansible runs locally, because OCI blocks
inbound SSH.

Four things `make` cannot do:

- Portainer: set the admin password at `portainer.cloud.merox.dev`
- Guacamole: change `guacadmin / guacadmin` immediately
- Pi-hole: verify DNS resolves
- Note the Tailscale IP; if it is not `100.72.22.38`, update
  `tailscale_expected_ip` in `vps/.../vps_servers/vars.yml`

**Without Hetzner:** clone the repo on the server, `make install`, `make setup`,
then `make app-stack-setup` — the app stack is not part of `make setup`.

## Phase 2 — Kubernetes (~20 min)

```bash
mise install                       # talosctl, kubectl, flux, task
cp <backup>/age.key ./age.key
```

Then edit three files for the new hardware. This is the only part DR.md does
not cover, because DR reuses prod's identity:

| File | Change |
|---|---|
| `talos/talconfig.yaml` | node IPs, VIP endpoint, `installDisk` (`/dev/sda` SATA/SAS, `/dev/nvme0n1` NVMe), `controlPlane.ingressAddress`. New Talos extensions mean a new image ID from factory.talos.dev |
| `kubernetes/components/common/cluster-vars.yaml` | every infrastructure IP — NFS server and all `LB_IP_*`. Injected into every namespace, so this is the single place to change them |
| `kubernetes/apps/kube-system/cilium/app/networks.yaml` | `blocks[0].cidr` — must contain every `LB_IP_*` above |

From a node in maintenance mode: `talosctl get disks -n <ip> --insecure` and
`talosctl get links -n <ip> --insecure`.

Then follow [`docs/dr-quickstart.md`](docs/dr-quickstart.md) from step 2 —
`dr:create-vms` through `dr:restore-prod`. Same eight commands.

**No Intel iGPU on the new hardware?** Remove the `gpu.intel.com/i915`
request from both Jellyfin HelmReleases and suspend
`intel-device-plugin-operator`. Jellyfin then transcodes in software.
[`docs/gpu-transcoding.md`](docs/gpu-transcoding.md) has the detail.

## Verify

```bash
bash scripts/dr-preflight.sh          # before you start
bash scripts/dr-verify.sh --phase 2   # after
```

Between them they check the vault, the secrets, backup/restore parity, node
and Flux health, PVC binding, CSI registration, DNS, certificates and the
Longhorn backup target. What they cannot check:

- [ ] Portainer admin password set
- [ ] Guacamole default credentials changed
- [ ] Joplin clients syncing
- [ ] Garage S3 credentials saved to vault
- [ ] Gateway reachable: `nmap -p 443 <LB_IP_GATEWAY_INTERNAL>`
- [ ] Old server decommissioned, Tailscale node removed

## Optional — instant Flux sync

```bash
kubectl -n flux-system get receiver github-receiver -o jsonpath='{.status.webhookPath}'
```

GitHub → Settings → Webhooks: `https://flux-webhook.merox.dev<path>`,
content type JSON, secret from `github-push-token.txt`, push events only.
