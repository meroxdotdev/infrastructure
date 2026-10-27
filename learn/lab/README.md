# learn/lab — fișierele laboratorului

Tot ce rulezi în curs. Lecțiile (`learn/docs/`) îți spun **când** și **de ce**;
aici e **ce**.

| Director | Ce e | Modul |
|---|---|---|
| `env.sh` | Planul de IP-uri și nume. Singurul loc unde le schimbi. | 01 |
| `versions.env` | Versiunile fixate (Kubernetes, etcd, containerd…), urmărite de Renovate | 06 |
| `infra/terraform/` | Cele 4 VM-uri pe Proxmox, cu cloud-init | 01 |
| `infra/router/` | `lab-gw`: NAT + firewall (nftables), BGP (FRR), S3 (Garage) | 01, 10, 14 |
| `hardway/` | Kubernetes de mână: PKI, etcd, control plane, kubelet, Cilium | 06–08 |
| `kubeadm/` | Același cluster, cu kubeadm, pentru comparație și DR | 19 |
| `k8s-lab/` | Șablonul repo-ului GitOps pe care îl urmărește ArgoCD | 12–19 |
| `exercises/` | Workload-uri stricate intenționat, de depanat | 18 |

## Topologia

```
            home LAN 10.57.57.0/24
 PC ───────────┬──────────────── pfSense 10.57.57.1
  (rută statică │
   10.10.0.0/16 │ 10.57.57.90
   via .90)     │
           ┌────┴─────┐
           │  lab-gw  │  router · jumpbox · FRR AS 65000 · Garage S3
           └────┬─────┘
                │ 10.10.0.1           lab 10.10.0.0/24 (vmbr10, doar intern)
   ┌────────────┼────────────┐
 k8s-1        k8s-2        k8s-3      AS 65001, control plane + worker
 .11          .12          .13        VIP API: 10.10.0.10 (keepalived)

 LoadBalancer: 10.10.100.0/24 (BGP)   Pods: 10.244.0.0/16   Services: 10.96.0.0/12
```

## Ordinea, pe scurt

```bash
# Pe PC (modulul 01)
cd learn/lab/infra/terraform && cp terraform.tfvars.example terraform.tfvars   # completează
tofu init && tofu apply

# Pe lab-gw (ssh -A ubuntu@10.57.57.90)
git clone https://github.com/meroxdotdev/infrastructure.git && cd infrastructure/learn/lab
sudo bash infra/router/setup-router.sh             # 01
bash hardway/00-jumpbox.sh                         # 06 …
bash hardway/01-prepare-nodes.sh
bash hardway/02-pki.sh && bash hardway/03-kubeconfigs.sh
bash hardway/04-etcd.sh                            # 06
bash hardway/05-control-plane.sh                   # 07
bash hardway/06-nodes.sh && bash hardway/07-addons.sh   # 08
sudo bash infra/router/setup-frr.sh                # 10
```

Fiecare script e idempotent (îl poți rula din nou) și comentat — citește-l
înainte să-l rulezi; comentariile sunt jumătate din lecție. Scripturile se
rulează cu `bash script.sh`: un checkout făcut pe Windows nu păstrează bitul
de execuție.
