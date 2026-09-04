# GPU Transcoding

Jellyfin hardware transcoding runs on **Intel QuickSync**, on the Beelink's
Iris Xe passed through to `kubernetes-1`. Both instances — `jellyfin`
and `jellyfin-public` — use it.

It ran on an Nvidia Quadro P2200 from 2026-07-17 to 2026-09-01. That stack is
gone; see the last section for what remains.

---

## Hardware / host

The iGPU sits alone in IOMMU group 0 on `pve-1` and is bound to `vfio-pci`.
Everything about that — `vfio.conf`, the module blacklists, the GRUB command
line — is recorded in
[../proxmox/pve-1/README.md](../proxmox/pve-1/README.md), along with the BIOS
settings that keep the iGPU present on a headless box.

VM config is one line: `hostpci0: 0000:00:02.0`, with `--machine q35` and
`--bios ovmf`. Inside the guest the device appears at `0000:06:10.0`.

## Talos

`kubernetes-1` runs Image Factory schematic
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

- `kubernetes/apps/kube-system/intel-device-plugin-operator/` — operator plus
  the `GpuDevicePlugin` CR, `sharedDevNum: 99`, exposing `gpu.intel.com/i915`.
- Both Jellyfin helmreleases request `gpu.intel.com/i915: 1`. Neither sets
  `runtimeClassName`, and neither needs `supplementalGroups`.

**Do not try to replace the plugin with a `/dev/dri` hostPath.** It was tried
on 2026-09-01 and cannot work: the device node is 0666 and appears correctly
inside the container, but the container's device cgroup denies `open()` on
char 226:128, so `vainfo` fails with `Failed to open the given device!`. Only
a device plugin — or `privileged: true`, which is not acceptable on an
internet-facing pod — adds the device to the allowlist.

**The consequence is that Jellyfin is pinned to pve-1**, since no other node
advertises the resource. During maintenance on that host, drop the request so
it can run anywhere on software transcoding:

```bash
kubectl -n default patch helmrelease jellyfin --type=json \
  -p '[{"op":"remove","path":"/spec/values/controllers/jellyfin/containers/app/resources/limits/gpu.intel.com~1i915"}]'
```

Flux puts it back on the next reconcile, so suspend the HelmRelease for the
duration (`flux suspend hr jellyfin -n default`) and resume when pve-1 is back.

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
`kubernetes-1`:

```bash
kubectl get pods -n default -o wide | grep jellyfin
```

## The Quadro, after retirement

Removed from git on 2026-09-01: the `nonfree-kmod-nvidia-lts` and
`nvidia-container-toolkit-lts` extensions from kubernetes-1's schematic (now
`36cd6536ea…b87c010`, carrying only intel-ucode + the two Longhorn tools),
`talos/patches/controller/nvidia-kernel-modules.yaml`, the
`nvidia.com/gpu` node labels, and `kubernetes/apps/kube-system/nvidia-device-plugin/`.

**The card itself stays in the R730xd**, unused, in case a future project wants
it. It costs **3.86 W** idle, measured in pstate P8 — about 34 kWh a year. It
causes no fan ramp: iDRAC cannot see it at all (`PCIe Slot1-4 = Not Readable`),
which `proxmox/pve-2/known-issues.md` records as never having triggered one.

It was detached from the old control-plane VM before that VM was retired:
`hostpci` makes a VM ineligible for live migration. That VM (800 on pve-2) was
destroyed on 2026-09-01 once the cluster had collapsed onto pve-1 and the
restore was verified; the card stayed in the chassis.

To use it again: regenerate a schematic with the two LTS extensions, restore
`nvidia-kernel-modules.yaml` and the device plugin from git history
(`c167dfc^`), upgrade the node, reattach `hostpci0`.
