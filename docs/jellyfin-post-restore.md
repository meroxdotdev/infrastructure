# Jellyfin — Post-Restore UI Configuration

After restoring the cluster, Jellyfin's GitOps config handles everything **except** a few settings
that must be set manually in the UI at `https://media.merox.dev` (Admin → Dashboard → Networking).

---

## Required Manual Steps (Admin → Networking)

### 1. LAN Networks

```
10.57.57.0/24, 10.57.97.0/24, 100.64.0.0/10
```

- `10.57.57.0/24` — main LAN / NAS subnet
- `10.57.97.0/24` — Kubernetes node subnet
- `100.64.0.0/10` — Tailscale CGNAT range

**Why:** Without these, Jellyfin treats Tailscale clients as "remote" and throttles bitrate even
though HW transcoding works. Tailscale subnet routing preserves the source IP (`100.x.x.x`),
so Jellyfin must know this range is trusted/local.

### 2. Known Proxies

```
10.57.57.101
```

This is the internal Cilium gateway LB IP. Without it, Jellyfin can't read `X-Forwarded-For`
headers correctly and doesn't see the real client IP.

Verify the IP is still correct with:
```bash
kubectl get gateway -n kube-system internal -o jsonpath='{.status.addresses}'
```

### 3. Published Server URIs

```
all=https://media.merox.dev
```

**Why:** Tells Jellyfin its public address. The env var `JELLYFIN_PublishedServerUris` in the
HelmRelease sets this automatically on pod start — verify it's populated in the UI after deploy.

---

## pfSense / Network Requirements

| What | Value |
|------|-------|
| Port forward | WAN UDP 41641 → `10.57.57.1:41641` (Tailscale on `fw`) |
| Tailscale subnets advertised | `10.57.57.0/24`, `10.57.97.0/24` |

**Why port forward matters:** Without it, Tailscale uses DERP relay (Germany/US), adding
significant latency to all streaming. With it, devices connect directly P2P to the home network.

Verify direct connections are established (run on `fw`):
```bash
tailscale status
# Devices should show "direct" not "relay"
```

---

## What GitOps Handles Automatically

- Intel i915 HW transcoding (`gpu.intel.com/i915: 1`, `supplementalGroups: [44]`)
- NFS media mount (read-only from Synology)
- Longhorn PVCs for config and metadata cache
- `JELLYFIN_PublishedServerUris` env var
- TLS via Cilium gateway (`media.merox.dev`)
