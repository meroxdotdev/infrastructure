# Jellyfin — Post-Restore & Configuration Reference

After restoring the cluster, Jellyfin's GitOps config handles the deployment automatically,
but several settings live **in the Longhorn PVC** (not in Git) and must be verified/re-applied
if restoring from an old backup.

---

## 1. Network Settings (Admin → Networking)

These are stored in `/config/config/network.xml` on the PVC. Verify after every restore.

### LAN Networks

```
10.57.57.0/24, 10.57.97.0/24, 100.64.0.0/10
```

| Subnet | Purpose |
|--------|---------|
| `10.57.57.0/24` | Main LAN / NAS subnet |
| `10.57.97.0/24` | Kubernetes node subnet |
| `100.64.0.0/10` | **Tailscale CGNAT range** — critical |

> Without `100.64.0.0/10`, Jellyfin treats Tailscale clients as "remote" and throttles bitrate.
> Tailscale subnet routing preserves the source IP (`100.x.x.x`), so Jellyfin must know this
> range is trusted/local to allow full bitrate.

### Known Proxies

```
10.57.57.101
```

The Cilium internal gateway LB IP. Without it, Jellyfin can't read `X-Forwarded-For` headers
and doesn't see the real client IP. Verify the IP is still correct:

```bash
kubectl get gateway -n kube-system internal -o jsonpath='{.status.addresses}'
```

### Published Server URIs

```
all=https://media.merox.dev
```

Set automatically by the env var `JELLYFIN_PublishedServerUris` in the HelmRelease.
Verify it's populated in the UI after deploy.

---

## 2. Encoding / Hardware Acceleration (Admin → Playback)

Stored in `/config/config/encoding.xml` on the PVC. **This file was manually optimized on
2026-05-27** for the i9-13900HK (Raptor Lake / Intel Iris Xe Gen 12.7). Re-apply if restoring
from a backup older than this date.

### Hardware Acceleration

| Setting | Value |
|---------|-------|
| Hardware acceleration | **Intel QuickSync (QSV)** |
| VAAPI device | `/dev/dri/renderD128` |
| QSV device | `/dev/dri/renderD128` |
| Low Power H.264 encoder | ✅ enabled |
| Low Power HEVC encoder | ✅ enabled |
| Hardware encoding | ✅ enabled |

### Supported Codecs — Hardware Decoding

| Codec | Support |
|-------|---------|
| H.264 | ✅ hardware (h264_qsv) |
| HEVC / H.265 | ✅ hardware (hevc_qsv) |
| VP9 | ✅ hardware (vp9_qsv) |
| AV1 | ✅ hardware **decode only** (av1_qsv) |
| MPEG-2 | ✅ hardware (mpeg2_qsv) |
| MPEG-4 | ✅ hardware |
| VC-1 | ✅ hardware (vc1_qsv) |

> ⚠️ **AV1 encoding is disabled.** The Iris Xe integrated GPU on i9-13900HK supports AV1
> *decode* but **not encode** via QSV. `av1_qsv` appears in ffmpeg's encoder list but crashes
> with exit code 218 when actually used. `AllowAv1Encoding = false` must stay.
>
> AV1 hardware *encoding* is only available on Intel Arc discrete GPUs (Alchemist/DG2+)
> and Intel Core Ultra (Meteor Lake, 14th gen+).

### Supported Codecs — Hardware Encoding (output)

| Codec | Support |
|-------|---------|
| H.264 | ✅ hardware (h264_qsv) |
| HEVC / H.265 | ✅ hardware (hevc_qsv) |
| AV1 | ❌ disabled (hardware doesn't support) |

### Tonemapping

| Setting | Value |
|---------|-------|
| VPP Tonemapping (HDR→SDR) | ✅ enabled — via Intel VPP hardware |
| Software tonemapping | disabled |
| Algorithm | bt2390 |

### Segment Management

| Setting | Value | Why |
|---------|-------|-----|
| Segment deletion | ✅ enabled | prevents GB of stale .mp4 files accumulating |
| Segment keep seconds | 120s | keep 2 min of buffer ahead, delete the rest |

### Re-applying the encoding.xml manually

If the PVC was restored from an old backup, re-apply via `kubectl exec`:

```bash
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=jellyfin -o jsonpath='{.items[0].metadata.name}')

# Check current state
kubectl exec -n default $POD -- grep -E "AllowAv1|AllowHevc|EnableVpp|LowPower|EnableSegment|HardwareDecodingCodecs" /config/config/encoding.xml

# Edit directly (make sure no active streams first)
kubectl exec -n default $POD -- vi /config/config/encoding.xml

# Or patch individual values with sed, e.g.:
kubectl exec -n default $POD -- sed -i \
  -e 's/<AllowAv1Encoding>true/<AllowAv1Encoding>false/' \
  -e 's/<AllowHevcEncoding>false/<AllowHevcEncoding>true/' \
  -e 's/<EnableSegmentDeletion>false/<EnableSegmentDeletion>true/' \
  /config/config/encoding.xml

# Restart pod to apply
kubectl rollout restart deployment/jellyfin -n default
```

---

## 3. Tailscale & Streaming Performance

### Setup

Tailscale runs on pfSense (`fw`, `10.57.57.1`), not in Kubernetes.
pfSense acts as a subnet router and advertises `10.57.57.0/24` to the Tailscale mesh.

| Requirement | Value |
|-------------|-------|
| Port forward | WAN **UDP 41641** → `10.57.57.1:41641` |
| Subnets advertised | `10.57.57.0/24`, `10.57.97.0/24` |

> Without the UDP 41641 port forward, Tailscale falls back to DERP relay (~5-10 Mbps max,
> high latency). With it, devices connect P2P directly to the home network (full bandwidth).

### Verifying direct P2P connection

```bash
# From the client device:
tailscale ping <tailscale-ip-of-pfsense>
# Should say: direct connection, not "via DERP"

# From pfSense:
tailscale status
# Devices should show "direct" not "relay"
```

### Recommended streaming quality by client

| Client type | Recommended max bitrate | Notes |
|-------------|------------------------|-------|
| LAN (local) | Original / 40+ Mbps | Direct play / remux — no transcode needed |
| Tailscale P2P (home wifi) | 20–40 Mbps | Full quality, P2P connection |
| Tailscale + mobile data (4G/5G) | **10–15 Mbps** | Mobile bandwidth varies; 15 Mbps sweet spot |
| Tailscale via DERP relay | 8–10 Mbps | Bandwidth-limited relay servers |

> **iPhone on Orange mobile data:** UPnP/PCP/NAT-PMP are unavailable (carrier CGNAT),
> but Tailscale can still establish direct P2P as long as the pfSense port forward is in place
> (server-initiated hole punch). Set max bitrate to 15 Mbps in the Jellyfin iOS app.

### Setting max bitrate in Jellyfin iOS app

`Settings → Video → Maximum Allowed Bitrate → 15 Mbps`

---

## 4. What GitOps Handles Automatically (HelmRelease)

These do **not** need manual intervention after restore:

| What | Where configured |
|------|-----------------|
| Intel i915 GPU device (`gpu.intel.com/i915: 1`) | `helmrelease.yaml` → `resources.limits` |
| Video group access (`supplementalGroups: [44]`) | `helmrelease.yaml` → `securityContext` |
| NFS media mount (read-only from Synology) | `helmrelease.yaml` → `persistence.media` |
| Longhorn PVCs for config + metadata cache | `pvc.yaml` |
| `JELLYFIN_PublishedServerUris` env var | `helmrelease.yaml` → `env` |
| TLS + ingress via Cilium Gateway (`media.merox.dev`) | `helmrelease.yaml` → `route` |
| Transcode temp dir (`/cache/transcodes`) | emptyDir in `helmrelease.yaml` |

---

## 5. Disaster Recovery Checklist

After a full cluster restore:

- [ ] Verify `network.xml` — LAN Networks includes `100.64.0.0/10`
- [ ] Verify `network.xml` — Known Proxies has `10.57.57.101`
- [ ] Verify `encoding.xml` — `HardwareAccelerationType = qsv`, `AllowAv1Encoding = false`, `AllowHevcEncoding = true`, `EnableSegmentDeletion = true`
- [ ] Verify Intel GPU is present: `kubectl exec -n default <pod> -- ls /dev/dri/`
- [ ] Verify NFS media mount: `kubectl exec -n default <pod> -- ls /media/`
- [ ] Test stream on LAN → should direct play (no transcode)
- [ ] Test stream via Tailscale → check `tailscale ping` shows direct, not DERP
- [ ] pfSense: confirm UDP 41641 port forward exists (WAN → `10.57.57.1:41641`)
