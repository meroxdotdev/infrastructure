# Sync — the folder that is there 24/7

One Syncthing folder, `Sync`, for what is in use right now and has to be at
hand from anywhere: the MacBook, the iPhone, the cluster, even with home
offline. Small by design (~25 GB); finished work moves to Synology Drive.

| Device | Copy | Address | Configured by |
|---|---|---|---|
| MacBook | full, `~/Sync` | `100.68.215.121:22000` (tailnet only) | Homebrew `syncthing`, `brew services` |
| homelab | full, `/var/syncthing/Sync` on a 40 Gi Longhorn volume | `10.57.57.103:22000` | [kubernetes/apps/default/syncthing](../kubernetes/apps/default/syncthing/app/helmrelease.yaml) |
| vps01 | **encrypted** — Oracle stores ciphertext it cannot read | `100.72.22.38:22000` (tailnet only) | [vps/roles/syncthing_node](../vps/roles/syncthing_node/README.md) |
| iPhone | what you open (on-demand) | dials the others | Synctrain |

## Rules

- **Nothing leaves the tailnet.** Global discovery, relays, NAT traversal and
  usage reporting are off on every node; peers are configured by address.
- **The VPS is untrusted.** It receives the folder as `receiveencrypted`. The
  encryption password is on the trusted devices only, and in the MacBook's
  Keychain as *Syncthing — encryption*.
- **History:** the MacBook and the homelab keep 30 days of replaced and
  deleted files (staggered versioning, `.stversions/`).
- **Backup:** the homelab copy is a Longhorn volume in the `backup` group, so
  it reaches the NAS, the vault and Oracle like every app volume.
- **Not for work data that must stay off third-party hosts.** The VPS copy is
  encrypted, but the folder is still the one place designed to be everywhere;
  `Job/` and `Clients/` belong in Drive.

Which side dials whom: the VPS cannot reach the MacBook (Tailscale ACL), so
the MacBook and the homelab dial the VPS. One direction is enough.

## Adding the iPhone

1. App Store → **Synctrain** (free, open source, Syncthing 2, files on
   demand; chosen over Möbius Sync, which is paid past 20 MB and still on the
   old engine). Settings: turn off *Global Discovery*, *Relays* and *NAT
   traversal*. Note its device ID.
2. Add the iPhone's ID as a device on the MacBook and the homelab (their GUIs
   below), share `Sync` with it — **no** encryption password: it is trusted.
3. On the iPhone, add the homelab (`tcp://10.57.57.103:22000`) and the VPS
   (`tcp://100.72.22.38:22000`) by ID and address, accept the folder.
   Tailscale must be on for either to be reachable.

## GUIs

```sh
open http://127.0.0.1:8384                                    # MacBook
kubectl -n default port-forward deploy/syncthing 8384         # homelab
ssh -L 8385:127.0.0.1:8384 ubuntu@100.72.22.38                # VPS, then :8385
```

## Rebuilding a node

Each node's identity is its own config (`config/` on the volume). A rebuilt
node gets a new device ID: remove the old one on the others, add the new one,
share the folder again — with the encryption password if it is the VPS.
