# `vault` — the R730xd on TrueNAS

The offline copy. Off ~22 h a day; pve-3 wakes it at `W`, it pulls from the
NAS, snapshots, pushes to Oracle, asks on Telegram, and powers itself off.
Built 2026-10-02 per [docs/plan-truenas-vault.md](../docs/plan-truenas-vault.md),
which holds the reasoning; this page is what is deployed.

| | |
|---|---|
| OS | TrueNAS 25.10 Community, update profile *Mission Critical* |
| Address | `vault`, `10.57.57.250`, port `eno4`; iDRAC `10.57.57.249` |
| Boot | `boot-pool`, mirror of two Intel D3-S4510 960 GB |
| Pool | `vault`, one RAIDZ3 of 12× 600 GB SAS, encrypted, auto-unlock |
| Access | SSH key-only as `truenas_admin`; web UI and SSH from the workstation only |

## Datasets

| Dataset | Written by | Off-site |
|---|---|---|
| `backup/nas` | the nightly pull: NAS `backups/` and `homes/` | yes, except `homes/merox/VMs` |
| `backup/github` | `git clone --mirror` of [config/github-repos](config/github-repos) | yes |
| `personal`, `work` | you, over SMB | yes, except `personal/Movies` and VM disks |
| `system` | these scripts, logs, config export, `secrets/` (0700) | yes, except `secrets/` |

## What runs

| When | What | From |
|---|---|---|
| `W` | `chassis power on` over IPMI, as Operator `vaultwake` | pve-3, [cron.d/vault-wake](../proxmox/pve-3/etc/cron.d/vault-wake) |
| boot | [vault-init.sh](scripts/vault-init.sh): starts the two below, detached | TrueNAS init script, POSTINIT |
| boot | [fan-control.sh](scripts/fan-control.sh): fans to the floor, iDRAC on anything odd | vault-init.sh |
| boot | [vault-nightly.sh](scripts/vault-nightly.sh): pull → mirrors → config → snapshots → restic → check → drill (1st) | vault-init.sh |
| `W` + 10 min | the same, for a vault kept on; one run per day | TrueNAS cron |
| end of run | [vault-gate.sh](scripts/vault-gate.sh): asks on Telegram, then powers off | vault-nightly.sh |
| `W` + 3 h | the gate alone, the backstop for a hung run | TrueNAS cron |
| 1st Sunday | scrub; SMART long (`midclt call disk.smart_test LONG '["*"]'`) | TrueNAS task; cron |

## Deploying a change

The scripts live on the pool, not on the root filesystem, which every TrueNAS
update replaces.

```sh
scp truenas/scripts/*.sh truenas_admin@vault:/tmp/
ssh truenas_admin@vault 'sudo install -o root -m 700 /tmp/*.sh /mnt/vault/system/scripts/'
```

restic is pinned, not TrueNAS's own (0.16 in 25.10): `/mnt/vault/system/bin/restic`,
checksum in [restic.sha256](restic.sha256).

## Everyday

```sh
ssh truenas_admin@vault 'tail -40 /mnt/vault/system/logs/nightly-$(date +%F).log'
ssh truenas_admin@vault 'sudo touch /mnt/vault/system/HOLD'   # keep on past today's run
```

Secrets: `vault.env` (template [vault.env.example](vault.env.example)),
`rsync-password`, `restic-password`, `rest-password`, `pwenc_secret` — all in
`/mnt/vault/system/secrets/`, all in the password manager.
