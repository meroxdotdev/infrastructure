# Talos Patching

Strategic-merge patches that `scripts/talos-genconfig.sh` passes to
`talosctl gen config`. `talconfig.yaml` lists which ones apply.

<https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/system-configuration/patching>

## Patch Directories

- `global/`: patches applied to every node (`--config-patch`)
- `controller/`: patches applied to control-plane nodes only (`--config-patch-control-plane`)

They target the v1alpha1 document, matching `configContract` in
`talconfig.yaml`. Moving to the v1.14 contract means porting them to the
multi-document format first.
