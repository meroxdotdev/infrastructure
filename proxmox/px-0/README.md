# proxmox/px-0

⚠️ **Not currently deployed (2026-08-25).** The Beelink hardware is still
owned, but isn't running Proxmox right now — out of scope, possibly a
future standalone dev cluster (undecided, along with px-1/px-2). Everything
below describes how it was configured when it last ran; kept as rebuild
reference, not as current state. `pve`/R730xd is the only live Proxmox
host — see [`proxmox/r730xd/README.md`](../r730xd/README.md).

Non-Ansible-managed VMs on px-0 (Beelink, `10.57.57.254`) — same convention
as [`proxmox/r730xd`](../r730xd/README.md): px-0 isn't in the Ansible
inventory, so these are provisioned/documented directly instead.

Rebuilding the host itself: [REINSTALL.md](REINSTALL.md). Captured host
config: [`etc/storage.cfg`](etc/storage.cfg),
[`etc/network-interfaces`](etc/network-interfaces).

⚠️ px-0 has **no backups at all** — no vzdump job, no `jobs.cfg`, both dump
directories empty (verified 2026-08-11). Every VM here is rebuild-only.
That is fine for what runs on it, but it is a choice, not an oversight:
`cluster-storage` is also a single NVMe with no redundancy.

Ollama runs on `pve`, not here — see
[`proxmox/r730xd/README.md`](../r730xd/README.md#ollama-vm).
