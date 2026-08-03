# DR Quickstart

One-page version of [`DR.md`](../DR.md) — same procedure, no explanations.
Read `DR.md` first if anything here is unclear; this page is a checklist,
not a tutorial.

**You need:** `age.key`, `talos/talsecret.sops.yaml`, SSH access to the
target Proxmox host, this repo checked out.

## 0. Pick a target host

| | px-0 | pve (R730xd) |
|---|---|---|
| Tests | real host failure | restore procedure only |
| RAM headroom | ~50GB free | 238GB+ free (once prod is stopped) |
| `vm_memory_mb` to use | `16384` | `49152` (matches prod) |
| `disk_storage` | `cluster-storage` | `local-zfs` |
| `iso_storage` | `local-data` | `media-isos` |

## 1. API token on the target host

```bash
ssh root@<target-host-ip>
pveum user token remove root@pam terraform 2>&1   # ignore "no such token"
pveum user token add root@pam terraform --privsep 0 --output-format json
# copy the "value" field — that's the token secret, shown once
```

## 2. `talos/terraform/terraform.tfvars`

Copy `terraform.tfvars.example` → `terraform.tfvars`, fill in:
- `proxmox_url` (target host's `https://<ip>:8006`)
- `proxmox_token_secret` (from step 1)
- `proxmox_nodes` / `disk_storage` / `iso_storage` — table above
- `vm_memory_mb` — table above
- **`node_macs`** — copy fresh from `talos/talconfig.yaml` `hardwareAddr`
  fields, every time. They drift.

## 3. Stop prod (only if reusing prod IPs/MACs, which is the default)

```bash
ssh root@<prod-proxmox-host> "qm shutdown 800; qm shutdown 802; qm shutdown 804"
```
Leaves the VMs off, untouched — nothing destroyed.

## 4. Create the DR VMs

```bash
cd talos/terraform
terraform init
terraform apply -auto-approve
```

## 5. Apply Talos configs (wait ~60s after step 4 first)

```bash
cd ../..
task dr:apply-talos-configs
```
If a node doesn't get matched (`UNKNOWN` MAC), find its current maintenance-mode
IP (`nmap -Pn -n -p 50000 --open 10.57.57.0/24`) and apply manually:
```bash
talosctl apply-config -n <ip> --insecure -f talos/clusterconfig/<file>.yaml
```

## 6. Bootstrap etcd + kubeconfig

```bash
cd talos
until talhelper gencommand bootstrap | bash; do sleep 10; done
until talhelper gencommand kubeconfig --extra-flags="$(pwd)/.. --force" | bash; do sleep 10; done
cd ..
kubectl get nodes    # NotReady is fine, no CNI yet
```

## 7. Bootstrap apps

```bash
export KUBECONFIG=./kubeconfig
task bootstrap:apps
kubectl get helmrelease longhorn -n longhorn-system -w   # ctrl-C once READY=True
```

macOS only, once per machine: `brew install bash helmfile kustomize`, and
make sure `/opt/homebrew/bin` is ahead of `/usr/bin` on `PATH`.

## 8. Restore Longhorn volumes

```bash
task longhorn:restore
```

## 9. Verify

```bash
kubectl get pods -A | grep -v "Running\|Completed"
kubectl get pvc -A | grep -v Bound
kubectl get helmreleases -A | grep -v "True\|READY"
```
`jellyfin` Pending + `nvidia-device-plugin` crashing = expected (no GPU on
DR nodes unless you added passthrough). Everything else should clear within
a few minutes — retry the `flux reconcile helmrelease <name> -n <ns>` for
anything still stuck after 5 min.

## 10. Done testing — clean up

```bash
cd talos/terraform
terraform destroy -auto-approve
ssh root@<prod-proxmox-host> "qm start 800; qm start 802; qm start 804"
```
