# GPU Transcoding

Jellyfin hardware transcoding runs on **Intel QuickSync**, on the Beelink's
Iris Xe passed through to `kubernetes-worker-1`. Both instances — `jellyfin`
and `jellyfin-public` — use it.

It ran on an Nvidia Quadro P2200 from 2026-07-17 to 2026-09-01. That stack is
still deployed but is being retired; see the last section.

---

## Hardware / host

The iGPU sits alone in IOMMU group 0 on `px-0` and is bound to `vfio-pci`.
Everything about that — `vfio.conf`, the module blacklists, the GRUB command
line — is recorded in
[../proxmox/px-0/README.md](../proxmox/px-0/README.md), along with the BIOS
settings that keep the iGPU present on a headless box.

VM config is one line: `hostpci0: 0000:00:02.0`, with `--machine q35` and
`--bios ovmf`. Inside the guest the device appears at `0000:06:10.0`.

## Talos

`kubernetes-worker-1` runs Image Factory schematic
`249d9135de54962744e917cfe654117000cba369f9152fbab9d055a00aa3664f`:

| Extension | Why |
|---|---|
| `siderolabs/i915` | the driver |
| `siderolabs/intel-ucode` | microcode |
| `siderolabs/iscsi-tools` | **Longhorn**, not the GPU — without it `longhorn-manager` crashloops |
| `siderolabs/util-linux-tools` | Longhorn |

Regenerate with the POST in
[operations.md](operations.md#variant-a-worker-that-transcodes) if the list
changes. Unlike the Nvidia extensions, `i915` needs no kernel-module patch and
no `RuntimeClass` — the device plugin injects `/dev/dri` directly.

`talos/talconfig.yaml` sets `intel.feature.node.kubernetes.io/gpu: "true"` on
the node. No Node Feature Discovery runs in this cluster, so it is placed by
hand; Jellyfin's node affinity is what reads it.

## Kubernetes

There is **no Intel device plugin**, deliberately. Both Jellyfin helmreleases
reach the GPU through a plain hostPath instead:

```yaml
dri:
  type: hostPath
  hostPath: /dev/dri
  hostPathType: DirectoryOrCreate
  globalMounts:
    - path: /dev/dri
```

paired with a `preferredDuringSchedulingIgnoredDuringExecution` affinity for
`intel.feature.node.kubernetes.io/gpu`. Neither sets `runtimeClassName`, and
neither needs `supplementalGroups` — Talos ships `renderD128` as 0666.

**Why not the device plugin.** `gpu.intel.com/i915: 1` is a hard resource
request, and only px-0 advertises it, so Jellyfin would sit `Pending` whenever
that host is down or in maintenance. Playback matters more than transcoding:
most of it is direct play, which needs no GPU at all. `DirectoryOrCreate` is
what makes the fallback graceful — on a node with no GPU the mount is an empty
directory, Jellyfin finds no QSV device and transcodes in software instead of
refusing to start.

The operator was briefly restored from `6bb0f3d` on 2026-09-01 and then
dropped again for exactly this reason. Do not reintroduce it without deciding
what should happen to Jellyfin while px-0 is down.

**One transitional wrinkle:** while the Quadro is still in pve, that node has
its own `/dev/dri/renderD128` from `nvidia_drm`. A Jellyfin pod landing there
mounts an Nvidia render node while configured for QSV, and transcodes will
fail rather than fall back cleanly. It resolves itself when the card leaves.

## Jellyfin encoding.xml

**Flux does not manage this.** It lives at `/config/config/encoding.xml` on
the Longhorn PVC, so switching the manifests does not switch the transcoder —
after the pods land on the worker, change it in
**Dashboard → Playback → Transcoding**, or the setting stays on NVENC and
every transcode fails.

| Setting | Value |
|---|---|
| `HardwareAccelerationType` | `qsv` |
| `EnableHardwareEncoding` | `true` |
| `EnableVppTonemapping` | `true` — Intel VPP tonemapping, unavailable on the Quadro |
| `EnableTonemapping` | `true` |
| `EnableIntelLowPowerH264HwEncoder` | `true` |
| `EnableIntelLowPowerHevcHwEncoder` | `true` |

Do not copy a codec list from here. Ask the hardware what it supports, from
inside the pod, and tick exactly that:

```bash
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=jellyfin -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n default "$POD" -- /usr/lib/jellyfin-ffmpeg/vainfo
```

The headline difference against the P2200: Raptor Lake decodes **AV1**, which
Pascal cannot, and encodes HEVC 10-bit. Neither chip encodes AV1.

## Verifying it actually works

`vainfo` only proves the driver loaded. Force a real encode:

```bash
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=jellyfin -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n default "$POD" -- ls -l /dev/dri
kubectl exec -n default "$POD" -- /usr/lib/jellyfin-ffmpeg/ffmpeg \
  -init_hw_device qsv=hw -filter_hw_device hw \
  -f lavfi -i testsrc=duration=5:size=1280x720:rate=30 \
  -vf format=nv12,hwupload=extra_hw_frames=64 -c:v h264_qsv -f null -
```

Look for `Stream mapping: ... -> h264_qsv`. Then force a transcode from a real
client and confirm Playback Info reports it, and that the pod is on
`kubernetes-worker-1`:

```bash
kubectl get pods -n default -o wide | grep jellyfin
```

## The Nvidia stack, pending retirement

Still deployed, nothing requests `nvidia.com/gpu` any more: the card itself,
the `nonfree-kmod-nvidia-lts` + `nvidia-container-toolkit-lts` extensions in
controlplane-1's schematic (`914e76a675…30c2dc`),
`talos/patches/controller/nvidia-kernel-modules.yaml` and
`kubernetes/apps/kube-system/nvidia-device-plugin/`.

It stays only until QuickSync has proven itself, then all of it goes in one
commit and the card comes out of the server. Keeping two GPU stacks configured
forever as a fallback costs more than the failure mode is worth. Selling the
card is a decision to take with the R730xd, not separately.
