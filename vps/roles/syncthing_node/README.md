# syncthing_node

The VPS's Syncthing: the always-on member of the shared `Sync` folder, so the
MacBook, the iPhone and the cluster stay in sync when home is down.

It is an **untrusted** device: it receives the folder encrypted
(`receiveencrypted`) and cannot read it. The encryption password lives on the
trusted devices and in the password manager, never here.

| | |
|---|---|
| Listens | `100.72.22.38:22000` (tailnet only) |
| GUI | `127.0.0.1:8384` — `ssh -L 8384:127.0.0.1:8384 ubuntu@100.72.22.38` |
| Data | `/srv/docker/syncthing` |
| Discovery, relays, NAT-PMP, usage reporting | off — peers are configured by address |

Pairing (device IDs, the folder, its encryption password) is Syncthing's own
state, done once through its API; rebuilding this node means pairing it again
from a trusted device, which re-sends the encrypted folder.
