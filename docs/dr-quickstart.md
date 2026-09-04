# DR Quickstart

Rebuild the whole cluster from scratch. Eight commands, no manual edits.
Reasoning lives in [`DR.md`](../DR.md).

**Last run:** 2026-08-29 on pve-1 — 71 min of prod downtime.

**You need:** `age.key`, `talos/talsecret.sops.yaml`, SSH to the target
Proxmox host, this repo. On macOS once:
`brew install bash helmfile kustomize yq`, with `/opt/homebrew/bin` ahead of
`/usr/bin` on `PATH`.

**Pick the target host first.** Every command below uses `$PVE`, because the
machine you rebuild onto depends on which one you still have. Set it once:

```bash
PVE=10.57.57.254   # pve-1, Beelink — the usual target
# PVE=10.57.57.250 # pve-2, R730xd — if pve-1 is what died
# PVE=10.57.57.253 # pve-3, OptiPlex — 32 GB, tight but it boots
```

This used to be hardcoded to pve-1, which quietly assumed the one machine
whose loss is the reason you would be reading this page was still running.

**Setup, once per machine:** copy `talos/terraform/terraform.tfvars.example`
to `terraform.tfvars` and paste the Proxmox API token. It is gitignored
because it holds that token; everything else in it is already filled in.

```bash
ssh root@$PVE "pveum user token add root@pam terraform --privsep 0"
```

Prod is three nodes since 2026-09-04, but **DR restores one**. That is
deliberate: one node is enough to get the workloads back, and a three-node DR
needs three hosts you may not have. `terraform.tfvars` carries the MACs it
creates; add nodes 2 and 3 there and in `talconfig.yaml` only if you are
rehearsing the full topology rather than recovering.

---

## Run

```bash
# 0. Catch drift before you start — fails if anything backed up nightly
#    is missing from the restore list
bash scripts/dr-preflight.sh

# 1. Stop prod — DR reuses its IP and MAC. Skip if the host is already gone.
ssh root@$PVE "qm shutdown 810 --timeout 180"

# 2. Create the DR VM(s)
task dr:create-vms

# 3. Apply Talos configs (wait ~60s first — nodes need to reach maintenance mode)
task dr:apply-talos-configs

# 4. Bootstrap etcd, fetch kubeconfig
task bootstrap:talos

# 5. Install Flux, Cilium, Longhorn and every app from Git
task bootstrap:apps

# 6. Restore all volumes from Garage S3
task longhorn:restore

# 7. Check
task dr:verify

# 8. Tear down and bring prod back (restore-prod can run 10-15 min)
task dr:destroy-vms
task dr:restore-prod
```

## What "healthy" looks like

```bash
kubectl get pods -A | grep -v "Running\|Completed"
kubectl get pvc -A | grep -v Bound          # must be empty
```

On a host without the Quadro P2200 exactly three things stay down, and
nothing else:

```
jellyfin              Pending
jellyfin-public       Pending
nvidia-device-plugin  Init:CrashLoopBackOff
```

That is the GPU being absent, not a fault. Everything else — including the
Immich photo library, the ARR configs, `jellyseerr` and `qbittorrent` — must
come back `Running` with its data.

## If something is off

`talosctl get machinestatus` reporting `booting` forever is normal on
GPU-less hardware: `ext-nvidia-persistenced` waits for a driver that will
never load. Judge the node by `talosctl services` instead — `etcd` and
`kubelet` at `Running/OK` means it is fine.

Anything else: [`dr-known-issues.md`](dr-known-issues.md) is the forensic
record of every failure mode already fixed, and why the code looks the way
it does.
