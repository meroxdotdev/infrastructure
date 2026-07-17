# GPU Transcoding — Nvidia (current) & Intel QSV (rollback)

Jellyfin hardware transcoding moved from Intel Quick Sync (iGPU passthrough on
px-0 / Beelink) to Nvidia NVENC/NVDEC (Quadro P2200 passthrough on the R730xd,
`10.57.57.250`) when `controlplane-1` was rebuilt on the R730xd. Both hardware
paths are documented here — the Intel config is **kept, not deleted**, as a
rollback option.

---

## 1. Current setup — Nvidia Quadro P2200

### Hardware / host (Proxmox, R730xd `10.57.57.250`)

The GPU (`04:00.0` VGA + `04:00.1` Audio, IOMMU group 19, cleanly isolated) is
passed through to the `kubernetes-controlplane-1` VM via `vfio-pci`.

Host-level config (mirrors the working Intel pattern from px-0):

| File                                                                               | Purpose                                                                                                                                    |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `/etc/default/grub` — `GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"` | Enable IOMMU (host is legacy GRUB, not `proxmox-boot-tool` — confirmed via `proxmox-boot-tool status` failing with "uuids does not exist") |
| `/etc/modprobe.d/blacklist-nvidia.conf`                                            | Blacklists `nvidia`, `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm` on the **host** so it never claims the GPU                               |
| `/etc/modprobe.d/vfio.conf`                                                        | `options vfio-pci ids=10de:1c31,10de:10f1` — binds both GPU functions to vfio-pci                                                          |
| `/etc/modules-load.d/vfio.conf`                                                    | `vfio`, `vfio_pci`, `vfio_iommu_type1`, `vfio_virqfd`                                                                                      |

VM config: `hostpci0: 0000:04:00.0` (video function only, no audio — Talos
doesn't need it), disk on `local-lvm` (low latency, required for etcd — not
`bulk-backups`).

### Talos

Quadro P2200 is **Pascal** (GP106) — the current Nvidia "production" driver
branch (595.x) dropped Pascal support (`NVRM: ... will ignore this GPU`).
Pascal requires the **LTS branch** (580.x):

- `talos/talconfig.yaml` — `kubernetes-controlplane-1` uses a custom Talos
  Image Factory schematic with extensions:
  `siderolabs/nonfree-kmod-nvidia-lts` + `siderolabs/nvidia-container-toolkit-lts`
  (schematic `914e76a6752e45504176b24f0f6a0a06f993c2dfa4cd314224f822f34730c2dc`,
  regenerate via the Image Factory API if the extension list changes — see
  `curl -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics`).
- `talos/patches/controller/nvidia-kernel-modules.yaml` — loads `nvidia`,
  `nvidia_uvm`, `nvidia_modeset`, `nvidia_drm` at boot (the extension alone
  does not auto-load them).
- Node labels on `kubernetes-controlplane-1`: `nvidia.com/gpu: "true"` and
  `nvidia.com/gpu.present: "true"`. The second label is required because the
  `nvidia-device-plugin` chart's default `nodeAffinity` looks for NFD labels
  we don't run (no Node Feature Discovery in this cluster) — `gpu.present`
  satisfies one of its OR'd affinity terms directly.
- containerd gets a `nvidia` runtime handler automatically from the
  `nvidia-container-toolkit` extension (`/etc/cri/conf.d/10-nvidia-container-runtime.part`),
  but Kubernetes needs an explicit `RuntimeClass` object to expose it — see
  `kubernetes/apps/kube-system/nvidia-device-plugin/app/runtimeclass.yaml`.

### Kubernetes

- `kubernetes/apps/kube-system/nvidia-device-plugin/` — Flux app (OCIRepository
    - HelmRelease, chart `nvidia-device-plugin` 0.19.3, mirrors the structure of
      `intel-device-plugin-operator/`). Exposes `nvidia.com/gpu` as an allocatable
      resource on labeled nodes.
- `kubernetes/apps/default/jellyfin/app/helmrelease.yaml`:
    - `resources.limits`: `nvidia.com/gpu: 1` (was `gpu.intel.com/i915: 1`)
    - `pod.runtimeClassName: nvidia`

### Jellyfin (`encoding.xml`, on the PVC — not in git, see

[jellyfin-post-restore.md](./jellyfin-post-restore.md))

| Setting                                              | Value                                                                                                                    |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `HardwareAccelerationType`                           | `nvenc`                                                                                                                  |
| `EnableHardwareEncoding`                             | `true`                                                                                                                   |
| `EnableVppTonemapping`                               | `false` (Intel-only)                                                                                                     |
| `EnableTonemapping`                                  | `true` (generic OpenCL/CUDA tonemapping)                                                                                 |
| `EnableIntelLowPowerH264HwEncoder` / `HevcHwEncoder` | `false` (Intel-only)                                                                                                     |
| `HardwareDecodingCodecs`                             | `h264`, `hevc`, `vc1`, `vp9`, `mpeg2video`, `mpeg4` — **no `av1`**: Pascal's NVDEC does not decode AV1 (added in Ampere) |

Encoding support on P2200: **decode** h264/hevc/vc1/vp9/mpeg2/mpeg4 (no AV1);
**encode** h264/hevc via NVENC (no AV1 encode on Pascal either).

### Verifying it actually works

Not just `nvidia-smi` — confirm a real transcode:

```bash
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=jellyfin -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n default "$POD" -- nvidia-smi
kubectl exec -n default "$POD" -- /usr/lib/jellyfin-ffmpeg/ffmpeg -hwaccel cuda \
  -f lavfi -i testsrc=duration=5:size=1280x720:rate=30 -c:v h264_nvenc -f null -
```

Then check `Stream mapping: ... -> h264_nvenc` in the output, and/or force a
transcode from an actual client and check Playback Info shows `nvenc`.

---

## 2. Rollback — Intel Quick Sync (iGPU, px-0 / Beelink)

Nothing was deleted. The previous `controlplane-1` VM (with working Intel
iGPU passthrough) is still on px-0 (`10.57.57.254`), **powered off, not
deleted** — VMID 800 there was the old identity before the R730xd rebuild.
The Intel GitOps manifests are still in git, just suspended.

To revert:

1. **Hardware**: power the old VM back on px-0 (`qm start 800` on
   `10.57.57.254`) — it will conflict with the current `controlplane-1` on
   R730xd (same MAC/IP), so the R730xd-based one must be removed from etcd
   first (`talosctl etcd remove-member`, same procedure used for the
   original migration, see git history around this doc's introduction).
   This is a full hardware rollback, not a quick toggle.
2. **GitOps**:
    - Un-suspend: remove `spec.suspend: true` from
      `kubernetes/apps/kube-system/intel-device-plugin-operator/ks.yaml`
      (both Kustomization blocks).
    - Remove/comment the `nvidia-device-plugin` line in
      `kubernetes/apps/kube-system/kustomization.yaml`.
    - `kubernetes/apps/default/jellyfin/app/helmrelease.yaml`: revert
      `resources.limits` to `gpu.intel.com/i915: 1` and drop
      `pod.runtimeClassName`.
    - `talos/talconfig.yaml`: revert `kubernetes-controlplane-1`'s
      `talosImageURL` to the plain (non-nvidia) schematic
      (`8d37fcc01bb9173406853e7fd97ad9eda40732043f88e09dafe55e53fcf4b510`),
      revert `nodeLabels` to `intel.feature.node.kubernetes.io/gpu: "true"`,
      and drop the `patches: [nvidia-kernel-modules.yaml]` entry.
3. **Jellyfin `encoding.xml`**: see the "Re-applying the encoding.xml
   manually" section in
   [jellyfin-post-restore.md](./jellyfin-post-restore.md) — set
   `HardwareAccelerationType` back to `qsv`, device `/dev/dri/renderD128`,
   re-enable the Intel Low-Power encoders and VPP tonemapping, restore `av1`
   to `HardwareDecodingCodecs` (Intel Iris Xe on the i9-13900H decodes AV1;
   Pascal does not).
