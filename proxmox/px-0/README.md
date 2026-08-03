# proxmox/px-0

Non-Ansible-managed VMs on px-0 (Beelink, `10.57.57.254`) — same convention
as [`proxmox/r730xd`](../r730xd/README.md): px-0 isn't in the Ansible
inventory, so these are provisioned/documented directly instead.

## Ollama VM (DONE, 2026-07-30)

Standalone VM (not a Talos node, not part of the K8s cluster) dedicated to
running Ollama for the alert-triage AI stack (see n8n in
`kubernetes/apps/default/n8n/`). Not a Talos node — px-0 hosts no K8s
control-plane VMs at all (all 3 run on the R730xd, see the root
`README.md` hardware table) — kept fully outside the cluster so Ollama
gets its own hypervisor-enforced memory ceiling instead of sharing a
kernel/cgroup tree with any kubelet.

- **VMID 105**, name `ollama`, IP `10.57.57.90` (static, cloud-init).
- 4 vCPU, 8GB RAM hard-capped (`balloon: 0` — won't grow into host
  headroom under pressure), 40GB disk on `cluster-storage` (ZFS).
- Ubuntu 24.04 LTS, cloud-init user `ollama`, SSH key-only
  (`/root/.ssh/ollama-vm-key` on px-0 — private key lives only there,
  same discipline as the other restricted keys documented in
  `proxmox/r730xd/README.md`).
- Ollama installed via the official install script, `OLLAMA_HOST=0.0.0.0`
  override in `/etc/systemd/system/ollama.service.d/override.conf` so it's
  reachable from the K8s cluster (default is loopback-only).
- Model: `qwen3:4b-instruct`, CPU inference (no GPU on this host — the
  only GPU passthrough is on R730xd/`controlplane-1`, already dedicated to
  Jellyfin with no time-slicing configured, so sharing it wasn't an
  option). Verified working: ~70ms per short completion once warm.
- API reachable at `http://10.57.57.90:11434` from anywhere on the LAN/K8s
  cluster (no auth — trusted network only, not exposed externally).

**Recreating this VM** (host loss, or starting over):

```bash
# on px-0, as root
cd /tmp && wget -q https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  -O ubuntu-2404-cloudimg.img
ssh-keygen -t ed25519 -f /root/.ssh/ollama-vm-key -N "" -C "root-to-ollama-vm"

qm create 105 --name ollama --memory 8192 --balloon 0 --cores 4 --cpu host \
  --net0 virtio,bridge=vmbr0,firewall=1 --scsihw virtio-scsi-single \
  --ostype l26 --agent enabled=1
qm importdisk 105 /tmp/ubuntu-2404-cloudimg.img cluster-storage
qm set 105 --scsi0 cluster-storage:vm-105-disk-0,iothread=1
qm set 105 --ide2 cluster-storage:cloudinit
qm set 105 --boot order=scsi0
qm set 105 --serial0 socket --vga serial0
qm set 105 --ipconfig0 ip=10.57.57.90/24,gw=10.57.57.1
qm set 105 --sshkeys /root/.ssh/ollama-vm-key.pub
qm set 105 --ciuser ollama
qm resize 105 scsi0 40G
qm start 105

# once booted (ssh -i /root/.ssh/ollama-vm-key ollama@10.57.57.90):
curl -fsSL https://ollama.com/install.sh | sudo sh
sudo mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\n' | sudo tee /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart ollama
ollama pull qwen3:4b-instruct
```

Nothing on this VM needs backing up — the model is a re-fetchable cache,
not unique data, and the OS is fully reproducible from the steps above.
