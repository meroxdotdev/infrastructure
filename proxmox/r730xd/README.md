# proxmox/r730xd

**Canonical reference for R730xd-side backup infrastructure** — README.md and
DR.md link here instead of repeating the schedule.

R730xd (`pve`, `10.57.57.250`) is the hub of the homelab backup mesh: it's
both the primary Longhorn (K8s) backup target and the landing spot for its
own VM/pfSense backups, then relays a curated copy on-prem to the Synology
and off-site to Oracle Cloud.

## The backup-orchestration LXC

Container 103 (`garage-r730xd`, `10.57.57.61` — static via a pfSense DHCP
reservation on MAC `bc:24:11:8b:b7:e9`, not a hand-set static IP) is a small
Debian 12 LXC (2 vCPU, 2GB RAM, unprivileged, `nesting=1`) whose only jobs
are: run Garage (below), and later host the Synology-relay and Oracle-restic
cron scripts. Provisioned via Ansible, not by hand:

```bash
cd vps
ansible-playbook -i inventories/production/hosts playbooks/garage-setup-r730xd.yml
```

Reuses `vps/roles/garage_setup` (same role as the VPS's own Garage instance)
with `garage_require_tailscale: false` and `garage_webui_enabled: false` —
this instance is LAN-only, no public domain, no Traefik. Both toggles default
`true` so the VPS's existing deployment is unaffected.

## Garage (Longhorn's backup target)

- S3 endpoint: `http://10.57.57.61:3900`, region `us-east-1`, bucket
  `longhorn` — same bucket/region names as the VPS's old instance, so
  `.taskfiles/longhorn/Taskfile.yaml`'s hardcoded `s3://longhorn@us-east-1/`
  string didn't need to change.
- Data lives on the `media` ZFS pool, **not** the LXC's own rootfs:
  `media/backups/longhorn-garage/{data,meta}`, bind-mounted into the LXC
  (owned by UID/GID 100000 on the host — the unprivileged container's root).
  This keeps the LXC itself stateless/reprovisionable and out of any vzdump
  job — only the ZFS-backed data matters, and that's exactly what the
  Synology/Oracle relays below need to touch anyway.
- Credentials: `docker exec garage /garage key info longhorn-key --show-secret`
  on the LXC. Consumed by Longhorn via
  `kubernetes/apps/storage/longhorn/app/minio-secret.sops.yaml`
  (`AWS_ENDPOINTS` points here).
- Cutover from the old VPS-hosted Garage instance: 2026-07-21. The old
  `longhorn` bucket on the VPS is left untouched as a rollback safety net for
  2+ weeks (see git history for the exact date) before its contents are
  removed.

## Source tree for downstream relays

```
/media/backups/
├── home-assistant/       vzdump, nightly 02:30
├── pdm/                  vzdump from px-0, nightly 02:00
├── pfsense/              config.xml.gz, nightly 03:00
└── longhorn-garage/      Garage data+meta (Longhorn's live backup store)
```

## Downstream legs

*To be filled in as built — Synology weekly cold clone and Oracle Cloud
encrypted restic push are tracked in the same implementation pass as this
Garage setup; this section will gain their schedule/retention details once
they're live.*

## Total-loss recovery

See ["R730xd / Garage total loss fallback"](../../DR.md#r730xd--garage-total-loss-fallback)
in DR.md.
