# Infrastructure Deploy Guide

Complete rebuild procedure for a new server: VPS → Kubernetes cluster.

---

## Prerequisites

Before starting, have these ready:

| Item                                 | Where to find it                                                                                                                               |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Vault password                       | Password manager                                                                                                                               |
| AGE key (`age.key`)                  | Backed up separately — **critical**                                                                                                            |
| Tailscale reusable auth key          | Tailscale admin console                                                                                                                        |
| Cloudflare API token                 | Cloudflare dashboard                                                                                                                           |
| Portainer EE license                 | Portainer account                                                                                                                              |
| Hetzner API token                    | console.hetzner.cloud → Security → API Tokens                                                                                                  |
| DR SSH key pair                      | `~/.ssh/cloudlab_dr_test` + `.pub` — on the prod VPS                                                                                           |
| R730xd backup push SSH key           | `vault_oracle_vps_to_r730xd_ssh_key` in vault — public half must be authorized on `root@pve` (see [proxmox/r730xd/README.md](proxmox/r730xd/README.md#oracle-vps--r730xd-done-2026-07-23)) |

**`vps/terraform/terraform.tfvars`** (gitignored — must be recreated on fresh machine):

```hcl
hcloud_token        = "<hetzner-api-token>"
ssh_public_key_path = "~/.ssh/cloudlab_dr_test.pub"
server_name         = "cloudlab-vps"
server_type         = "cax21"
server_location     = "nbg1"
allowed_ips         = ["0.0.0.0/0", "::/0"]
```

> Generate SSH key if missing: `ssh-keygen -t ed25519 -f ~/.ssh/cloudlab_dr_test -C "cloudlab-dr-test" -N ""`

---

## Phase 1 — VPS

> ~15 min. Sets up: SSH hardening, fail2ban, Docker, Tailscale, Traefik, Cloudflare Tunnel,
> Pi-hole + Unbound, Portainer, Homepage, Joplin + Postgres, Uptime Kuma, Guacamole, Glances,
> Authentik SSO, Garage S3, Netdata, Beszel, Dozzle.
>
> **How it works:** Terraform provisions the Hetzner server (cloud-init installs python3 + creates dirs).
> `make dr-full` then runs Ansible from your local machine over SSH to deploy all services.
> This differs from the Oracle Cloud production setup, where Ansible runs locally on the server
> (inventory uses `ansible_connection=local` since OCI blocks SSH from external IPs).

### Option A — Terraform + Hetzner (recommended for DR)

> **Prerequisite:** `vault_tailscale_auth_key` must be valid (Tailscale keys expire after 90 days).
> Verify at `tailscale.com/admin/settings/keys` before starting. Then:
>
> ```bash
> cd vps/ && make vault-edit   # update vault_tailscale_auth_key
> git add inventories/production/group_vars/all/vault.yml && git commit -m "fix: update tailscale auth key" && git push
> ```

```bash
cd vps/

# First time only
make terraform-init

# Run pre-flight checks, then provision + deploy
make dr-full
# dr-full = dr-preflight + terraform apply + SSH poll until ready + Ansible setup + app-stack-setup
```

Reads vault password from `.vault_pass` automatically — no prompt.
Tailscale and Let's Encrypt certs connect automatically.

After deploy completes, restore all service data from R730xd
(`root@10.57.57.250:/media/backups/oracle-vps/srv-backups/` — nightly pushes
from the VPS, see `vps/roles/vps_backup/README.md`):

```bash
cd vps && make dr-restore     # non-interactive: pulls from R730xd, restores DBs + extras
```

`make dr-restore` runs the full restore sequence: pulls `srv-backups/` from
R730xd, drops + re-imports the Authentik + Joplin DBs from the latest dump
(Authentik comes back with full state — providers, flows, apps, users; Joplin
clients re-sync afterwards), and restores Guacamole / Traefik certs / Pi-hole /
Homepage / Portainer from their tarballs. See
`vps/roles/vps_backup/README.md` for the full breakdown of each step.

If R730xd itself is also gone, the same data is one hop further out on
Synology (`/volume1/NetBackup/oracle-vps/<latest-date>/`) or, failing that,
in Oracle's own Hyper Backup copy — see
[proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs) for
that chain.

Verify Phase 1 is healthy:

```bash
make dr-verify-phase1   # run on the VPS (or: bash scripts/dr-verify.sh --phase 1)
```

**Tailscale IP:** the new VPS will likely get a different `100.x.x.x` tailnet IP.
`dr-verify-phase1` prints it and warns if it changed from `100.72.22.38`. The
`make dr-restore` step above already auto-repoints Pi-hole's `*.cloud.merox.dev`
local DNS records (joplin, agents, traefik, status, garage, etc.) to the new
IP — see `vps/roles/vps_backup/README.md`. Two things still need a manual
update if the IP changed:

- the Storage Cloud link in
  `kubernetes/apps/default/homepage/app/resources/services.yaml`
  (the NAS off-site sync auto-detects its own IP, so nothing else there).
- `tailscale_expected_ip` in `vps/inventories/production/group_vars/vps_servers/vars.yml`
  — bump it to the new IP so the _next_ DR's auto-repoint diffs from the
  right baseline.

**IMPORTANT — before Phase 2:** extract Garage S3 credentials and save to vault:

```bash
make garage-extract-creds   # run on the VPS — extracts keys + updates vault automatically
```

> **DR-over-SSH note:** `garage-extract-creds` and `dr-verify-phase1` assume they run
> _on_ the VPS (local `docker ps`/`docker exec`). When running from your Mac/Linux
> machine via `make dr-full` (SSH mode), they currently fail/false-negative. Workaround
> used during the 2026-06-13 drill:
>
> ```bash
> # verify (from local machine):
> scp scripts/dr-verify.sh root@<NEW_IP>:/tmp/ && ssh root@<NEW_IP> "bash /tmp/dr-verify.sh --phase 1"
>
> # garage creds (from local machine):
> ssh root@<NEW_IP> "docker exec garage /garage key info longhorn-key --show-secret"
> # then manually upsert garage_access_key_id / garage_secret_access_key into vault:
> cd vps
> ansible-vault decrypt inventories/production/group_vars/all/vault.yml \
>   --vault-password-file .vault_pass --output /tmp/vault-plain.yml
> # edit /tmp/vault-plain.yml, add/update the two garage_* keys, then:
> ansible-vault encrypt /tmp/vault-plain.yml --vault-password-file .vault_pass \
>   --encrypt-vault-id default --output inventories/production/group_vars/all/vault.yml
> shred -u /tmp/vault-plain.yml
> ```
>
> (`--encrypt-vault-id default` is required because `ansible.cfg` already sets
> `vault_password_file`, which combined with `--vault-password-file` makes
> `ansible-vault` see two `default` vault-ids.)

**IMPORTANT — Longhorn BackupTarget (K8s side):** the new Garage instance has a
**new** access key + secret + Tailscale IP. Longhorn's `minio-secret` (used by the
`BackupTarget` CR) must be updated and resynced, or Longhorn backups/restores will
silently fail (`BackupTarget available: false`):

```bash
export SOPS_AGE_KEY_FILE=./age.key
sops -d -i kubernetes/apps/storage/longhorn/app/minio-secret.sops.yaml
# edit AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (from garage-extract-creds above)
# and AWS_ENDPOINTS (http://<new-tailscale-ip>:3900)
sops -e -i kubernetes/apps/storage/longhorn/app/minio-secret.sops.yaml

# apply immediately (Flux will pick it up too, but this is instant):
sops --decrypt kubernetes/apps/storage/longhorn/app/minio-secret.sops.yaml | kubectl apply -f -

# force Longhorn to re-check the backup target now instead of waiting ~5min:
kubectl -n longhorn-system patch backuptargets.longhorn.io default --type=merge \
  -p "{\"spec\":{\"syncRequestedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"

# verify:
kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}'
# expect: true
```

**Cloudflare Tunnel (cloudflared):** deployed automatically by the `cloudflared_setup`
role (added 2026-06-13) — runs as a `network_mode: host` container so it can reach
`localhost:3000` (Homepage), `localhost:3001` (Uptime Kuma), `localhost:443` (Traefik),
and `172.25.10.72:9000` (Authentik), matching the tunnel's remotely-managed ingress
rules (`config_src: cloudflare` — ingress is stored on Cloudflare's side, nothing to
re-configure per-deploy).

> **Requires `cloudflare_tunnel_token` in vault** (the _connector_ token from
> Cloudflare Zero Trust → Networks → Tunnels → "one" → Configure — looks like
> `eyJhIjoi...`). This is **different** from `homepage_cloudflare_token` (an API
> token used only by Homepage's Cloudflared widget). As of 2026-06-13 this var is
> **not yet in vault** — until it's added, `inside.merox.dev`, `sso.merox.dev`,
> `rmt.merox.dev`, and `status.merox.dev` are unreachable from
> the internet after a fresh deploy (container runs but logs
> `Provided Tunnel token is not valid`). One-time fix:
>
> ```bash
> cd vps && make vault-edit   # add: cloudflare_tunnel_token: "eyJhIjoi..."
> ansible-playbook playbooks/site.yml --tags cloudflared
> ```

> **Known issue — Docker 29.x + fresh install:** on a brand-new Hetzner server, the
> first `apt install docker-ce` pulls the latest Docker (29.x). The `docker_setup`
> role's `notify: restart docker` (fired by the daemon.json + package-install tasks)
> then triggers `systemctl restart docker`, which on this Docker version can come
> back with **`docker ps -a` showing zero containers** (containerd tasks are torn
> down and not restored), even though all compose files/volumes under
> `/srv/docker/oracle-cloud/*/` are intact. This was hit during the 2026-06-13 drill
> when re-running `ansible-playbook --tags cloudflared,uptime-kuma` after the
> initial `make dr-full`. Recovery (recreates all containers from existing compose
>
> - data, ~30s):
>
> ```bash
> ssh root@<IP> 'for d in /srv/docker/oracle-cloud/*/ /srv/docker/cloudflared/; do (cd "$d" && docker compose up -d); done'
> ```
>
> If running the full `make dr-full` in one shot (not re-running scoped tags
> afterwards), this has not been observed to cause data loss — only re-triggering
> `docker_setup`'s handlers on a _second_ ansible run on the same fresh box.

### Option B — Existing server / manual provisioning

> **Note:** The inventory uses `ansible_connection=local` — Ansible must run **on the server itself**, not from a remote machine.

```bash
# 1. SSH into the server, then clone the infrastructure repo
ssh root@<SERVER_IP>
git clone https://github.com/meroxdotdev/infrastructure /opt/infrastructure
cd /opt/infrastructure/vps
echo "<vault-password>" > .vault_pass && chmod 600 .vault_pass

# 2. Install Ansible collections
make install

# 3. Full deploy
make setup

# 4. Deploy the app stack (Homepage, Pi-hole, Portainer, Joplin, Glances —
#    cloudlab-merox repo, not part of `make setup`)
make app-stack-setup
```

> **DNS note:** all web traffic goes through Cloudflare Tunnel — no A records to update.
> The tunnel reconnects automatically with the same token on the new server.
> Tailscale also reconnects automatically via the auth key in vault.

**Post-deploy manual steps:**

```bash
# Portainer: set admin password at https://portainer.cloud.merox.dev
# Guacamole: change default credentials (guacadmin / guacadmin) immediately
# Pi-hole: verify DNS at https://pihole.cloud.merox.dev/admin
# Joplin: clients will sync automatically once server is up

# Retrieve Garage S3 credentials and save to vault:
ssh root@<NEW_IP> "docker exec garage /garage key info longhorn-key --show-secret"
ansible-vault edit inventories/production/group_vars/all/vault.yml
# Add: garage_access_key_id and garage_secret_access_key
```

**Verify:**

```bash
make health-check
```

---

## Phase 2 — Kubernetes Cluster

> ~20 min. Talos Linux + FluxCD + all apps via GitOps.

> **DR test or restore onto Proxmox DR VMs?** That's a different procedure — see
> **[DR.md](DR.md)** (`task dr:create-vms` + `task dr:apply-talos-configs`, restore
> from S3, ~35 min, tested end-to-end). This phase covers a real rebuild on new
> or existing hardware.

```bash
cd /srv/kubernetes/infrastructure/

# 1. Install tools (mise manages talosctl, kubectl, flux, task, etc.)
mise trust && mise install

# 2. Place AGE key
cp /path/to/age.key ./age.key

# 3. Adapt config for new hardware — edit these 3 files:

# --- a) Node IPs, VIP, install disk ---
# Edit: talos/talconfig.yaml
#   nodes[*].ipAddress          → new node IPs
#   endpoint                    → new VIP (e.g. https://10.x.x.88:6443)
#   nodes[*].installDisk        → /dev/sda (SATA/SAS) or /dev/nvme0n1 (NVMe)
#   controlPlane.ingressAddress → new VIP
#
# NOTE: if you add/remove Talos extensions (GPU, iSCSI, etc.) generate a new
# image ID at https://factory.talos.dev and update talosImageURL
#
# To get disk and MAC info from a node booted in maintenance mode:
#   talosctl get disks -n <ip> --insecure
#   talosctl get links -n <ip> --insecure

# --- b) All infrastructure IPs used by apps (Flux postBuild substitution) ---
# Edit: kubernetes/components/common/cluster-vars.yaml
#   NFS_SERVER              → R730xd (pve) IP - serves media/photos/backups NFS exports
#   HOMEPAGE_PROXMOX_IP     → Proxmox host IP
#   HOMEPAGE_ROUTER_IP      → Router/gateway IP
#   HOMEPAGE_MYSPEED_IP     → MySpeed service IP
#   LB_IP_GATEWAY_INTERNAL  → Cilium internal gateway LB IP
#   LB_IP_QBITTORRENT       → qBittorrent LB IP
#   LB_IP_PORTAINER         → Portainer agent LB IP
#   LB_IP_K8S_GATEWAY       → k8s-gateway (DNS) LB IP
#   LB_IP_GATEWAY_EXTERNAL  → Cilium external gateway LB IP
#
# These values are injected into every namespace via the 'common' Kustomize
# component. This is the single place to change all infrastructure IPs.

# --- c) Cilium LB pool subnet ---
# Edit: kubernetes/apps/kube-system/cilium/app/networks.yaml
#   blocks[0].cidr           → new subnet (e.g. "10.x.x.0/24")
#   Must contain all LB_IP_* values above.

# 4. Verify nodes are booted into Talos maintenance mode and reachable
#    (replace with your subnet)
nmap -Pn -n -p 50000 10.57.57.0/24 -vv | grep 'Discovered'

# 5. Bootstrap Talos on all nodes (~10 min)
task bootstrap:talos
git add -A && git commit -m "chore: add secrets" && git push
```

### Bootstrap apps + restore volumes

```bash
# 6. Bootstrap Flux and wait for Longhorn to be ready
#    helmfile.yaml installs: cilium, coredns, spegel, cert-manager,
#    prometheus-operator-crds (pre-installs CRDs before Flux reconciles
#    kube-prometheus-stack), flux-operator, flux-instance
task bootstrap:apps

# Wait until Longhorn HelmRelease is Ready (~3-5 min):
kubectl -n longhorn-system wait helmrelease/longhorn --for=condition=Ready --timeout=10m
# Verify all 3 Longhorn nodes appear:
kubectl -n longhorn-system get nodes.longhorn.io

# 7. CRITICAL: Remove duplicate default/longhorn HelmRelease
#    Longhorn 1.11.2 namespace-scoped feature creates a spurious copy in default namespace.
#    This duplicate breaks CSI driver registration and prevents ALL volume attachments.
#    Must be removed BEFORE proceeding.
if kubectl get helmrelease longhorn -n default &>/dev/null; then
  echo "Removing duplicate default/longhorn..."
  kubectl delete helmrelease longhorn -n default
  helm uninstall longhorn -n default 2>/dev/null || true
  kubectl delete deployment csi-attacher csi-provisioner csi-resizer \
    csi-snapshotter longhorn-driver-deployer longhorn-ui \
    -n default --ignore-not-found
  kubectl delete daemonset longhorn-manager longhorn-csi-plugin -n default --ignore-not-found
  kubectl rollout restart daemonset/longhorn-csi-plugin -n longhorn-system
  kubectl rollout status daemonset/longhorn-csi-plugin -n longhorn-system --timeout=60s
  # Verify driver.longhorn.io is registered on all nodes:
  kubectl get csinodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.drivers[*].name}{"\n"}{end}'
fi

# 8. Restore all Longhorn volumes from S3 backup
#    This single command handles: BackupTarget patch, volume creation,
#    pvs.yaml apply, prometheus/alertmanager PVCs, and Flux reconcile.
task longhorn:restore

# Monitor until all pods are Running (~5-10 min):
kubectl get pods -A --watch
```

**Verify Phase 2:**

```bash
# One-shot: bash scripts/dr-verify.sh --phase 2
# Or manually:

# Nodes and Flux
kubectl get nodes                                    # All Ready
kubectl get kustomizations -A                        # All True
flux get sources git flux-system                     # READY True

# Storage — all PVCs must be Bound
kubectl get pvc -A | grep -v Bound | grep -v NAME    # Should be empty
kubectl get volumes.longhorn.io -n longhorn-system | grep restored  # attached/healthy
kubectl get pv | grep restored                       # All Bound

# CSI driver registered on all nodes (REQUIRED)
kubectl get csinodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.drivers[*].name}{"\n"}{end}'
# Expected: each node shows "nfs.csi.k8s.io driver.longhorn.io"

# No duplicate Longhorn in default namespace
kubectl get helmrelease longhorn -n default 2>/dev/null && echo "ERROR: duplicate found" || echo "OK"

# Networking
cilium status                                        # All OK
nmap -Pn -n -p 443 10.57.57.101 10.57.57.112 -vv   # Both gateways reachable
dig @10.57.57.111 echo.merox.dev                    # Should resolve to 10.57.57.112
kubectl -n network describe certificates            # Certificate Ready
```

**Longhorn backup target (verify after restore):**

```bash
# BackupTarget is a CRD in Longhorn 1.11.2 (not a Setting anymore):
kubectl get backuptarget default -n longhorn-system -o jsonpath='{.spec}'
# Expected: backupTargetURL=s3://longhorn@us-east-1/, credentialSecret=minio-secret
# task longhorn:restore already patches this automatically.
```

**GitHub Webhook (optional — enables instant Flux sync on git push):**

```bash
# Get the webhook path
kubectl -n flux-system get receiver github-webhook \
  --output=jsonpath='{.status.webhookPath}'
# Output looks like: /hook/12ebd1e363c641dc3c2e430ecf3cee2b3c7a5ac9e1234506f6f5f3ce1230e123

# Full webhook URL:
# https://flux-webhook.merox.dev/hook/<path-from-above>

# In GitHub repo → Settings → Webhooks → Add webhook:
#   Payload URL: https://flux-webhook.merox.dev/hook/<path>
#   Content type: application/json
#   Secret: contents of github-push-token.txt
#   Events: Just the push event
```

---

## Migration Checklist

```
[ ] vault_tailscale_auth_key valid and pushed before dr-full
[ ] make dr-preflight — all checks PASS (no FAIL)
[ ] Phase 1 complete — make dr-full finished, all containers up (make dr-verify-phase1)
[ ] Tailscale IP noted (dr-verify-phase1 prints it) — if different from 100.72.22.38,
    update kubernetes/apps/default/homepage/app/resources/services.yaml (Storage Cloud link)
[ ] make garage-extract-creds — Garage S3 credentials saved to vault (REQUIRED before Phase 2)
[ ] kubernetes/apps/storage/longhorn/app/minio-secret.sops.yaml updated (new Garage
    access key + secret + Tailscale IP) and applied; BackupTarget available=true
[ ] cloudflare_tunnel_token present in vault and cloudflared container connected
    (docker logs cloudflared — no "Tunnel token is not valid"; check
    https://inside.merox.dev loads)
[ ] All data restored — make dr-restore (pulls from R730xd, restores DBs + extras)
[ ] Tailscale connected (verify: ssh root@<IP> tailscale status)
[ ] Portainer admin password set
[ ] Guacamole default credentials changed (guacadmin / guacadmin → new password)
[ ] Joplin clients syncing to new server
[ ] Garage S3 credentials saved to vault
[ ] AGE key placed at /srv/kubernetes/infrastructure/age.key
[ ] talos/talconfig.yaml updated (node IPs, VIP, installDisk, talosImageURL if changed)
[ ] kubernetes/components/common/cluster-vars.yaml updated (all infrastructure IPs — NFS, router, LB IPs)
[ ] kubernetes/apps/kube-system/cilium/app/networks.yaml updated (subnet cidr, must contain all LB IPs)
[ ] Nvidia Quadro P2200 passthrough present on new hardware for controlplane-1 — required for Jellyfin HW transcoding
    (if no GPU: remove nvidia.com/gpu + runtimeClassName from jellyfin helmrelease + suspend nvidia-device-plugin;
    see docs/gpu-transcoding.md for the Intel QSV rollback path, kept suspended in git for this scenario)
[ ] Nodes reachable on port 50000 (nmap verification)
[ ] Phase 2 complete — all nodes Ready, Flux healthy, cilium status OK (make dr-verify-phase2)
[ ] Longhorn volumes restored (task longhorn:restore ran successfully)
[ ] All PVCs bound (kubectl get pvc -A | grep -v Bound → empty)
[ ] Gateway TCP connectivity OK (nmap -p 443 on LB_IP_GATEWAY_INTERNAL + LB_IP_GATEWAY_EXTERNAL)
[ ] DNS resolution OK (dig @LB_IP_K8S_GATEWAY echo.merox.dev)
[ ] Wildcard certificate Ready (kubectl -n network describe certificates)
[ ] Longhorn backup target working (test a manual backup)
[ ] GitHub Webhook configured (optional — for instant Flux sync on git push)
[ ] Old server decommissioned / Tailscale node removed
```

---

## What lives where

| Asset                                                                                                       | Location                                                                                                                                 | Backed up?                                  |
| ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| K8s manifests + Ansible roles                                                                               | This git repo                                                                                                                            | ✅                                          |
| Kubernetes secrets (SOPS)                                                                                   | Git-encrypted with AGE                                                                                                                   | ✅                                          |
| AGE encryption key                                                                                          | `age.key` (gitignored)                                                                                                                   | ⚠️ Back up manually                         |
| Vault password                                                                                              | Password manager                                                                                                                         | ⚠️ Stored externally                        |
| Ansible vault secrets                                                                                       | `vps/inventories/production/group_vars/all/vault.yml` (encrypted)                                                                        | ✅ in git                                   |
| Longhorn volumes (media/ARR configs + Immich's Postgres, group `media`)                                     | Nightly to a self-hosted Garage instance on R730xd (`proxmox/r730xd/`) — moved off the VPS 2026-07-21                                    | ✅ relayed to Synology + Oracle, see below  |
| VPS service state (Authentik + Joplin DB dumps, Guacamole, Traefik certs, Pi-hole config, Homepage, Portainer) | Nightly push to R730xd (`/media/backups/oracle-vps/`) — schedule & details: [vps/roles/vps_backup/README.md](vps/roles/vps_backup/README.md) | ✅ relayed to Synology + Oracle, see below  |
| R730xd's own backup tree (the row above + photos, documents, VM backups, pfSense config, Garage data, Immich Postgres dumps) | Weekly to Synology (cold storage) — [proxmox/r730xd/README.md](proxmox/r730xd/README.md#downstream-legs)                                | ✅ 3 versions kept                          |
| Synology's copy of the above                                                                                | Weekly to Oracle Cloud via Hyper Backup (rsync, encrypted) — same README, "Synology → Oracle Cloud"                                      | ✅ 3 versions kept, off-site                |
| Observability history (Prometheus/Loki/Grafana), `*-cache` volumes, Uptime-Kuma                             | —                                                                                                                                        | ❌ deliberately not backed up (regenerable) |

**The one thing to back up manually, off this VPS entirely:**

`age.key` — losing this means losing all SOPS-encrypted K8s secrets. Not
covered by any of the above since it never touches the VPS or R730xd.
