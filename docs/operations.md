# Operations

Day-to-day commands and routine maintenance. Broken things:
[troubleshooting.md](troubleshooting.md). Rebuilding: [../DR.md](../DR.md).

## Day-to-day

### Cluster

```bash
kubectl get nodes
kubectl get kustomizations -A
kubectl get helmreleases -A
cilium status

task reconcile                              # force Flux sync

task talos:generate-config                  # after editing talconfig.yaml
task talos:apply-node IP=10.57.57.80        # apply config to a node
task talos:upgrade-node IP=10.57.57.80      # upgrade Talos on a node
task talos:upgrade-k8s                      # upgrade Kubernetes version
```

### Headlamp (K8s dashboard)

- URL: `https://headlamp.k8s.merox.dev` (internal gateway only)
- Login: bearer token for the `headlamp` ServiceAccount (`cluster-admin`
  via the `headlamp-admin` ClusterRoleBinding)

```bash
kubectl create token headlamp -n default --duration=8760h
```

⚠️ Run it directly in a terminal. Copy-pasting through a chat/markdown UI
can carry hidden characters that corrupt the cookie → "Error
authenticating".

### VPS

```bash
cd vps/

make health-check       # verify all services are running
make setup              # full redeploy (idempotent)
make update             # OS package updates only
make check              # dry-run (--check --diff)
make restore            # interactive restore wizard (Joplin / Authentik / all)
make cleanup            # remove unused Docker images/volumes
make dr-full            # provision fallback VPS + cloud-init deploys everything (~15 min)
```

---

## Maintenance

### Adding a node

```bash
# Keep an odd number of control-plane nodes (1, 3, 5) for quorum
talosctl get disks -n <new-node-ip> --insecure    # find the install disk
talosctl get links -n <new-node-ip> --insecure    # find the MAC address
# Add entry to talos/talconfig.yaml with disk + MAC
task talos:generate-config
task talos:apply-node IP=<new-node-ip>
kubectl get nodes --watch
```

### Automatic updates (Renovate)

Renovate runs every weekend and opens PRs automatically for:

- Helm chart versions (all HelmReleases)
- Container image tags (annotated with `# renovate:`)
- Talos / Kubernetes versions (`.mise.toml`)

Config: `.renovaterc.json5`

### SOPS secret rotation

```bash
sops kubernetes/apps/<namespace>/<app>/app/secret.sops.yaml
# After rotating the AGE key:
find . -name "*.sops.*" -exec sops updatekeys {} \;
```

### Security

- Kubernetes secrets: SOPS/AGE encrypted (back up `age.key` separately — it's critical)
- Ansible secrets: encrypted Vault (`vps/`)
- All traffic: Tailscale mesh or Cloudflare Tunnel (zero open ports)
