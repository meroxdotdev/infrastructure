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

### Adding a worker node

Adds compute without touching etcd. The control-plane count stays odd — one
today, deliberately ([../talos/SINGLE-NODE.md](../talos/SINGLE-NODE.md)) — so a
second physical host joins as a worker, not as a second control plane. Two
control planes are strictly worse than one: they cannot form a quorum.

**The cluster has no workers today** — it collapsed to the single node
`kubernetes-1` on 2026-09-01. This runbook is kept because adding one is a
reasonable thing to want, and because the traps below cost a day to find.

Worked example: `kubernetes-worker-1`, **VM 811** on `px-0` (10.57.57.254),
node address 10.57.57.81. Do not reuse VM 810 or 10.57.57.80 — those are
`kubernetes-1`, the live cluster.

**Check the version skew first.** A new node is built from `talos/talenv.yaml`,
so if that file is ahead of the running control plane the worker boots with a
kubelet newer than the API server — unsupported, and it will not stay healthy.

```bash
kubectl get nodes -o wide                      # VERSION column
yq '.kubernetesVersion' talos/talenv.yaml       # what a new node would get
```

If talenv is ahead, upgrade the control plane first: `task
talos:upgrade-node IP=10.57.57.80` then `task talos:upgrade-k8s`.

**1. Fetch the ISO** onto the target host, once. This is the schematic the
plain (non-GPU) nodes used — no extensions:

```bash
ssh root@10.57.57.254 'cd /local_data/template/iso && curl -Lo talos-v1.13.9-metal-amd64.iso \
  https://factory.talos.dev/image/8d37fcc01bb9173406853e7fd97ad9eda40732043f88e09dafe55e53fcf4b510/v1.13.9/metal-amd64.iso'
```

Name it with the version. The directory already holds ISOs from earlier
rebuilds, including an undated `metal-amd64.iso` — booting the wrong one
installs the wrong Talos and the mistake only shows up as a skew error later.

**2. Create the VM.** Terraform is not involved — `talos/terraform/` provisions
DR VMs only, and this node is permanent.

```bash
ssh root@10.57.57.254 'qm create 811 --name kubernetes-worker-1 --tags k8s \
  --cores 8 --sockets 1 --cpu host --memory 32768 --numa 0 \
  --ostype l26 --bios ovmf --machine q35 --scsihw virtio-scsi-single --onboot 1 \
  --boot "order=scsi0;ide2" \
  --net0 "virtio=BC:24:11:00:57:81,bridge=vmbr0,firewall=1" \
  --scsi0 "cluster-storage:250,format=raw,iothread=1,ssd=1" \
  --efidisk0 "cluster-storage:1,efitype=4m" \
  --ide2 "local-data:iso/talos-v1.13.9-metal-amd64.iso,media=cdrom"'
```

The MAC is not cosmetic. `networkInterfaces[].deviceSelector.hardwareAddr` in
`talconfig.yaml` selects the NIC by MAC, so a VM whose MAC disagrees with the
file boots with no address and no way in. Pick the MAC here, then paste the
same one into git.

Boot order is disk-then-ISO on purpose: the empty disk falls through to the
ISO for the install, and every boot afterwards comes off the disk. Detach the
ISO once the node is up.

**3. Boot it** and wait ~60s for maintenance mode. It takes a DHCP lease first:

```bash
ssh root@10.57.57.254 'qm start 811'
nmap -Pn -n -p 50000 --open 10.57.57.0/24      # find the maintenance-mode node
```

**4. Declare it in git.** Add the node to `talos/talconfig.yaml`. Put any node
labels in the node's own `nodeLabels:`, the way `kubernetes-controlplane-1`
does — do **not** uncomment the `worker:` patches block at the bottom of the
file. The only thing it carries is `longhorn: "true"`, which nothing reads:
`longhorn-manager` is a DaemonSet with no `nodeSelector` and
`system-managed-components-node-selector` is empty, so every node is a Longhorn
node whether it has the label or not.

```yaml
  - hostname: "kubernetes-worker-1"
    ipAddress: "10.57.57.81"
    installDisk: "/dev/sda"
    controlPlane: false
    machineSpec:
      secureboot: false
    talosImageURL: factory.talos.dev/installer/8d37fcc01bb9173406853e7fd97ad9eda40732043f88e09dafe55e53fcf4b510
    networkInterfaces:
      - deviceSelector:
          hardwareAddr: "bc:24:11:00:57:81"
        dhcp: false
        addresses:
          - "10.57.57.81/24"
        routes:
          - network: "0.0.0.0/0"
            gateway: "10.57.57.1"
        mtu: 1500
```

No `vip:` block — the VIP (10.57.57.88) belongs to control-plane nodes only.

**5. Apply the config.** The first apply must be `--insecure` against the DHCP
address. `task talos:apply-node` does not work yet: its preconditions read a
machineconfig the node does not have.

```bash
task talos:generate-config
talosctl apply-config --insecure -n <dhcp-ip> \
  -f talos/clusterconfig/kubernetes-kubernetes-worker-1.yaml
```

The node installs, reboots onto 10.57.57.81 and joins by itself — workers are
never bootstrapped, only control planes are. From here on the normal task
works: `task talos:apply-node IP=10.57.57.81`.

```bash
kubectl get nodes -w
```

**6. Decide its storage role.** Longhorn picks up any node carrying the
`longhorn: "true"` label as a scheduling target. Whether a given node should
hold replicas is a separate decision from whether it runs pods — read the
comments in
[../kubernetes/apps/storage/longhorn/app/helmrelease.yaml](../kubernetes/apps/storage/longhorn/app/helmrelease.yaml)
for why `defaultReplicaCount` is 1 before changing it. To keep a node
compute-only:

```bash
kubectl -n longhorn-system patch nodes.longhorn.io kubernetes-worker-1 \
  --type=merge -p '{"spec":{"allowScheduling":false}}'
```

#### Variant: a worker that transcodes

For a node that has to run Jellyfin, three things change.

**A different schematic.** The plain image above has no extensions. Build the
list by diffing against what the control plane already runs, not by thinking
about the GPU alone:

```bash
talosctl -n 10.57.57.80 get extensions
```

The GPU needs `siderolabs/i915` and `siderolabs/intel-ucode`. **Longhorn needs
`siderolabs/iscsi-tools` and `siderolabs/util-linux-tools` on every node** —
without `iscsiadm`, `longhorn-manager` crashloops with `failed to check
environment` and no volume can ever attach there. That failure appears minutes
after the node looks `Ready`, so it is easy to build the image without them.

```bash
cat > /tmp/schematic.yaml <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/i915
      - siderolabs/intel-ucode
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
EOF
curl -X POST --data-binary @/tmp/schematic.yaml https://factory.talos.dev/schematics
```

The request is idempotent — the same extension list always returns the same id.
For this set it is
`249d9135de54962744e917cfe654117000cba369f9152fbab9d055a00aa3664f`, which is
what `kubernetes-worker-1` runs. Use it for both the ISO URL and
`talosImageURL`, in place of the plain schematic above.

Getting this wrong is recoverable without rebuilding the node: fix
`talosImageURL`, then `task talos:generate-config`, `task talos:apply-node`,
`task talos:upgrade-node IP=… DRAIN=false`. The node reboots onto the new
extension set in about a minute.

**The GPU on the VM.** On `px-0` the iGPU is alone in IOMMU group 0 and already
bound to `vfio-pci`, left over from when that host ran the Intel setup — so
nothing has to be prepared on the host:

```bash
ssh root@10.57.57.254 'qm set 811 --hostpci0 0000:00:02.0'   # the iGPU is already claimed by 810
```

**The node label.** Set `intel.feature.node.kubernetes.io/gpu: "true"` in the
node's own `nodeLabels:`. `intel-device-plugin-operator` is already deployed
(`kubernetes/apps/kube-system/`) and its DaemonSet selects on that label; it
exposes `gpu.intel.com/i915`, which is what Jellyfin requests. Nothing else is
needed on the Kubernetes side.

#### NFS: the export ACL is per host

`/etc/exports` on pve lists client IPs one by one, not the subnet — see the
comment at the top of
[../proxmox/r730xd/etc/exports](../proxmox/r730xd/etc/exports). A new node is
not on that list, so every inline NFS mount (Jellyfin, jellyfin-public,
qbittorrent, radarr-public) fails to mount on it with a permission error that
looks nothing like an ACL problem. Add the node's address to each export line
and `exportfs -ra`, in the repo copy and on the host both.

### Removing a worker node

```bash
kubectl drain kubernetes-worker-1 --ignore-daemonsets --delete-emptydir-data
kubectl delete node kubernetes-worker-1
talosctl reset -n 10.57.57.81 --graceful=false --reboot
# then delete the node block from talconfig.yaml, and the VM
ssh root@10.57.57.254 'qm stop 811 && qm destroy 811'
```

### Rebuilding the cluster on the same hardware

The 2026-09-01 collapse to one node was a deliberate DR run. Four things cost
time that the quickstart did not warn about:

- **`talosctl reset` needs `--endpoints`** when the endpoint in `talosconfig`
  is a node you have already stopped. Otherwise it tries to reach the target
  *through* the dead one and times out with a confusing dial error.
- **A reset node comes back on DHCP**, not on its old static address — the
  reset wipes `STATE`, and the static address lives there. Find it with
  `nmap -Pn -n -p 50000 --open 10.57.57.0/24`, do not wait on the old IP.
- **Check what the requests actually add up to.** A VM sized as a worker looks
  too small for the whole cluster: 32 GiB left Jellyfin `Pending` on
  `Insufficient memory` against 38 GiB of requests, and the conclusion written
  here was to resize to 44 GiB. That resize was never applied, this page said
  it had been for two days, and on 2026-09-03 the same Pending returned.

  The VM was not the problem. Thirteen containers declared a memory limit and
  no memory request, so Kubernetes copied each limit into its request: 38 GiB
  reserved against about 9 GiB in use. With requests set to limit/8 the same
  workload sits at 28% of the same 32 GiB VM. `kubernetes-1` runs 14 cores /
  32 GiB / 350 GB and needs no more.

  Growing the VM instead would have worked for a while and hidden the same
  fault until it was 44 GiB of reservations.
- **Take a fresh backup first.** `longhorn:restore` restores the newest backup
  in S3, and the nightly job runs at 23:50 — anything changed during the day
  is not in it. Fire the job early by patching its cron a few minutes ahead,
  then put the cron back.

```bash
kubectl -n longhorn-system patch recurringjob backup-homelab-k8s \
  --type=merge -p '{"spec":{"cron":"<mm> <hh> * * *"}}'   # a few minutes out, UTC
# wait for the Job to complete, then:
kubectl -n longhorn-system patch recurringjob backup-homelab-k8s \
  --type=merge -p '{"spec":{"cron":"50 23 * * *"}}'
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
