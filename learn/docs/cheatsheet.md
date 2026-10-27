# Fișă de comenzi

Grupate pe unealtă, în ordinea în care le vei folosi. Toate rulează pe lab-gw, dacă nu scrie
altfel.

## kubectl — starea

```bash
kubectl get pods -A -o wide                                  # tot, cu nodul și IP-ul
kubectl get pods -A --field-selector status.phase!=Running   # ce nu merge
kubectl get events -A --sort-by=.lastTimestamp | tail -20    # ce s-a întâmplat recent
kubectl describe pod <pod> -n <ns>                           # Events la final: aproape mereu răspunsul
kubectl logs <pod> -n <ns> --previous                        # logul instanței care a murit
kubectl logs -n <ns> deploy/<nume> -f --all-containers
kubectl get <tip> <nume> -o yaml | less                      # obiectul complet, cu status
kubectl explain deployment.spec.strategy --recursive         # documentația câmpurilor, offline
kubectl api-resources | grep -i <cuvânt>                     # ce tipuri există (CRD-uri incluse)
kubectl get --raw='/readyz?verbose'                          # sănătatea API-ului, pe componente
```

## kubectl — acțiuni

```bash
kubectl -n <ns> rollout status|history|undo|restart deploy/<nume>
kubectl -n <ns> exec -it deploy/<nume> -- sh
kubectl -n <ns> port-forward svc/<nume> 8080:80
kubectl -n <ns> run t --rm -it --image=busybox:1.37 --restart=Never -- sh
kubectl debug node/k8s-1 -it --image=busybox:1.37            # shell pe nod, fără SSH
kubectl cordon|uncordon|drain <nod> --ignore-daemonsets --delete-emptydir-data
kubectl auth can-i <verb> <resursă> -n <ns> --as=<user> [--as-group=<g>]
kubectl top nodes; kubectl top pods -A --sort-by=memory
```

## Pe nod

```bash
systemctl status kubelet containerd etcd kube-apiserver
journalctl -u kubelet -n 100 --no-pager
sudo crictl pods; sudo crictl ps -a; sudo crictl logs <id>; sudo crictl inspect <id>
sudo crictl pull <imagine>                                   # eroarea brută a registry-ului
sudo ctr -n k8s.io images ls | head
sudo dmesg -T | tail -30                                     # OOM, disc, rețea
cat /var/lib/kubelet/config.yaml
sudo ss -tlnp
```

## etcd

```bash
source ~/hardway/etcdctl.env
etcdctl endpoint health --cluster
etcdctl endpoint status --cluster -w table                   # lider, DB size, raft index
etcdctl member list -w table
etcdctl get /registry --prefix --keys-only | head            # ce stochează Kubernetes
etcdctl --endpoints=https://10.10.0.11:2379 snapshot save ~/etcd.db
etcdutl snapshot status ~/etcd.db -w table
```

## Certificate

```bash
openssl x509 -in cert.crt -noout -subject -issuer -dates -ext subjectAltName,extendedKeyUsage
openssl verify -CAfile ca.crt cert.crt
openssl s_client -connect 10.10.0.10:6443 -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -noout -subject
```

## Rețea

```bash
ip -br a; ip route; ip neigh
ip route get <ip>
sudo tcpdump -ni <interfață> host <ip> and port <port>
sudo nft list ruleset
sudo conntrack -L | grep <ip>
dig @10.96.0.10 <nume>.svc.cluster.local +short
```

## Cilium și Hubble

```bash
cilium status
cilium bgp peers
cilium bgp routes advertised ipv4 unicast
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
hobs() { for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$p" -c cilium-agent -- hubble observe "$@" 2>/dev/null; done; }
hobs --verdict DROPPED --last 50
hobs -n <ns> --protocol tcp --last 20
cilium hubble ui
```

## FRR (pe lab-gw)

```bash
sudo vtysh -c 'show bgp summary'
sudo vtysh -c 'show ip route bgp'
sudo vtysh -c 'show bgp ipv4 unicast 10.10.100.20/32'
sudo vtysh -c 'show bgp neighbors 10.10.0.11 received-routes'
sudo vtysh -c 'clear bgp ipv4 unicast * soft in'
```

## Helm, Kustomize

```bash
helm show values <repo>/<chart> --version <v>
helm template <release> <repo>/<chart> --version <v> -f values.yaml | less
helm -n <ns> list; helm -n <ns> history <release>; helm -n <ns> get values <release>
kubectl kustomize <dir>
kubectl diff -k <dir>                                        # ce s-ar schimba în cluster
```

## ArgoCD

```bash
argocd app list
argocd app get <app> --refresh                               # recitește Git acum
argocd app diff <app>
argocd app sync <app> [--prune]
argocd app wait <app> --health --timeout 600
argocd app history <app>
argocd app set <app> --self-heal=false                       # temporar, pentru un experiment
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

## Sealed Secrets, cert-manager, Longhorn

```bash
kubectl create secret generic <n> -n <ns> --from-literal=k=v --dry-run=client -o yaml | kubeseal --format yaml > <n>.sealed.yaml
kubeseal --fetch-cert > pub.pem
kubectl get certificate,certificaterequest,order,challenge -A
kubectl describe certificate <n> -n <ns>
kubectl -n longhorn-system get volumes.longhorn.io,replicas.longhorn.io
kubectl -n longhorn-system get backuptarget,backupvolumes.longhorn.io
```

## OpenTofu și Proxmox

```bash
tofu plan; tofu apply; tofu state list; tofu destroy        # pe PC, în learn/lab/infra/terraform
qm list; qm start|stop|shutdown <vmid>                       # pe hostul Proxmox
qm snapshot <vmid> <nume>; qm rollback <vmid> <nume>; qm listsnapshot <vmid>
```

## Scripturile lab-ului

```bash
cd ~/infrastructure/learn/lab
bash hardway/00-jumpbox.sh … 07-addons.sh                    # instalarea, în ordine
ONLY=k8s-2 bash hardway/06-nodes.sh                          # un singur nod (upgrade, rotație)
RUNTIME_ONLY=1 bash hardway/06-nodes.sh                      # doar containerd (kubeadm)
bash hardway/reset.sh                                        # șterge clusterul, păstrează OS-ul și PKI-ul
sudo bash infra/router/setup-frr.sh | setup-garage.sh
```
