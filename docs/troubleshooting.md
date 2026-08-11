# Troubleshooting

Symptom-first. Routine commands: [operations.md](operations.md).
Restore procedures: [../DR.md](../DR.md).


## Flux not reconciling

```bash
flux get sources git -A
flux get kustomizations -A
flux logs --level=error
flux reconcile kustomization cluster-apps --with-source
```

## HelmRelease stuck / failed

```bash
kubectl get helmreleases -A | grep -v True
flux logs --kind HelmRelease --name <name> -n <namespace>
flux reconcile helmrelease <name> -n <namespace> --with-source
# If Helm refuses changes — suspend + resume:
flux suspend helmrelease <name> -n <namespace>
flux resume helmrelease <name> -n <namespace>
```

## Pod issues

```bash
kubectl -n <namespace> get pods -o wide
kubectl -n <namespace> describe pod <pod>
kubectl -n <namespace> logs <pod> -f
kubectl -n <namespace> logs <pod> --previous
kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
```

## Longhorn storage

```bash
kubectl -n longhorn-system get volumes
kubectl -n longhorn-system get nodes.longhorn.io

# Remove orphaned replicas (safe)
kubectl get orphan -n longhorn-system -o name | \
  xargs kubectl delete -n longhorn-system
```

## Replacing a disk on a K8s node

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# Proxmox: shut down VM, swap physical disk, start VM
task talos:generate-config
talosctl apply-config --insecure --nodes <ip> \
  --file talos/clusterconfig/<node>.yaml
kubectl uncordon <node>
# If Longhorn disk UUID changed → evict replicas via UI, re-add new disk
```

> Wait 1-2 hours between disk swaps to allow replica rebuild.

## Node unreachable

```bash
talosctl -n <node-ip> health
talosctl -n <node-ip> dmesg
talosctl -n <node-ip> services
kubectl describe node <node-name>
```

## Garage S3

```bash
docker exec garage /garage status
docker exec garage /garage bucket list
kubectl -n longhorn-system get secret minio-secret
```

