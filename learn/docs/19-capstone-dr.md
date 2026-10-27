# Capstone: totul din Git, de la zero

Proba finală e cea pe care prod o exersează cu cronometrul: distrugi clusterul și îl
reconstruiești doar din ce ai în afara lui — repo-ul, două chei și backup-urile. De data
asta cu **kubeadm**, ca să vezi în 20 de minute tot ce ai făcut de mână în trei module, și
să-l poți numi pas cu pas.

## Ce trebuie să existe în afara clusterului

Înainte să distrugi ceva, verifică lista. E echivalentul secțiunii „Three secrets you cannot
lose” din [README](../../README.md) și al [dr-preflight.sh](../../scripts/dr-preflight.sh):

| Ce | Unde | Fără el |
|---|---|---|
| Repo-ul `k8s-lab`, împins pe GitHub | GitHub | nu ai ce reconstrui |
| Backup-ul cheii Sealed Secrets | `~/sealed-secrets-key.backup.yaml` (modulul 13) — **nu** în Git | niciun `*.sealed.yaml` nu mai e decriptabil |
| Backup-uri Longhorn recente | Garage, pe lab-gw | volumele pornesc goale |
| Lista volumelor de restaurat | PV-uri statice (modulul 14) | restaurezi și apoi nu se leagă nimic |
| `learn/lab` (env.sh, scripturi) | repo-ul infrastructure | — |

- [ ] Verifică fiecare rând din tabel și notează ora: de aici pornește cronometrul

## Partea 1 — distrugerea

```bash
cd ~/infrastructure/learn/lab
bash hardway/reset.sh            # tastează „reset”
for ip in 10.10.0.11 10.10.0.12 10.10.0.13; do ssh ubuntu@$ip sudo reboot; done
# Binarele hard-way rămân în /usr/local/bin; scoate-le, ca să nu umbrească pachetele kubeadm:
for n in k8s-1 k8s-2 k8s-3; do ssh $n 'sudo rm -f /usr/local/bin/kube-apiserver /usr/local/bin/kube-controller-manager /usr/local/bin/kube-scheduler /usr/local/bin/kubelet /usr/local/bin/kubectl'; done
```

> [!CAUTION]
> **💥 Ireversibil**
> `reset.sh` șterge etcd, toate volumele Longhorn de pe noduri și starea containerd. Ce nu e
> în tabelul de mai sus e pierdut. E exact scopul exercițiului — dar fă-l după ce ai verificat
> tabelul, nu înainte. (Snapshot-urile Proxmox `cluster-up` din modulul 08 sunt plasa ta de
> siguranță dacă vrei să revii la clusterul hard way.)

## Partea 2 — clusterul, cu kubeadm

### Runtime, VIP, pachete

```bash
RUNTIME_ONLY=1 bash hardway/06-nodes.sh          # containerd + runc + CNI plugins, ca în modulul 08
bash hardway/keepalived.sh                       # același VIP

for n in k8s-1 k8s-2 k8s-3; do ssh $n 'bash -s' <<'EOF'
set -e
sudo install -d -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update -qq && sudo apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
sudo apt-mark hold kubelet kubeadm kubectl >/dev/null
echo "KUBELET_EXTRA_ARGS=--node-ip=$(ip -4 -o route get 10.10.0.1 | awk '{print $5}')" | sudo tee /etc/default/kubelet
kubeadm version -o short
EOF
done
```

`apt-mark hold`: un `apt upgrade` de rutină n-are voie să urce kubelet-ul peste apiserver
(modulul 18). Repo-ul `pkgs.k8s.io` e per minor (`v1.36`) din același motiv: un upgrade de
minor e o schimbare de repo, deliberată.

### Primul nod

Citește [kubeadm-config.yaml](../lab/kubeadm/kubeadm-config.yaml): fiecare câmp are un
corespondent în ce ai scris de mână.

```bash
scp kubeadm/kubeadm-config.yaml k8s-1:/tmp/
ssh k8s-1 sudo kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs | tee ~/kubeadm-init.log
mkdir -p ~/.kube && ssh k8s-1 sudo cat /etc/kubernetes/admin.conf > ~/.kube/config
kubectl get nodes
```

### Celelalte două

Din `~/kubeadm-init.log`, comanda `kubeadm join … --control-plane --certificate-key …`. Pe
fiecare nod rămas, adaugă adresa proprie:

```bash
JOIN=$(grep -A2 'kubeadm join' ~/kubeadm-init.log | head -3 | tr -d '\\\n')   # prima comandă: cea --control-plane
ssh k8s-2 "sudo $JOIN --apiserver-advertise-address 10.10.0.12"
ssh k8s-3 "sudo $JOIN --apiserver-advertise-address 10.10.0.13"
kubectl get nodes -o wide                        # NotReady: încă fără CNI, ca în modulul 08
```

`serverTLSBootstrap: true` înseamnă că fiecare kubelet a cerut un certificat de server
printr-un CSR. Aprobă-le — e exact `kubelet-<nod>-serving` din `02-pki.sh`, emis de
controller-manager:

```bash
kubectl get csr
kubectl get csr -o name | xargs kubectl certificate approve
```

### Ce a făcut kubeadm, în limba ta

```bash
ssh k8s-1 sudo kubeadm init phase --help | sed -n '/Available Commands/,/Flags/p'
ssh k8s-1 sudo kubeadm certs check-expiration
ssh k8s-1 ls /etc/kubernetes/manifests/
```

| Faza kubeadm | Ce ai făcut tu | Diferența |
|---|---|---|
| `preflight` | `01-prepare-nodes.sh` | kubeadm doar *verifică*; tu ai și *configurat* |
| `certs` | `02-pki.sh` | aceleași trei CA-uri, aceleași certificate; RSA în loc de ECDSA; plus `etcd/healthcheck-client` |
| `kubeconfig` | `03-kubeconfigs.sh` | plus `super-admin.conf` cu `system:masters`; `admin.conf` folosește `kubeadm:cluster-admins` (modulul 17) |
| `etcd local` | `04-etcd.sh` | static pod în `/etc/kubernetes/manifests`, nu unit systemd |
| `control-plane` | `05-control-plane.sh` | tot static pods; kubelet-ul le pornește, le repornește și le raportează ca *mirror pods* |
| `kubelet-start` | `06-nodes.sh` | config în `/var/lib/kubelet/config.yaml`, bootstrap token în loc de certificat făcut de mână |
| `upload-config`, `upload-certs` | `scp` + staging | CA-ul și cheile comune, criptate într-un Secret, pentru nodurile care se alătură |
| `mark-control-plane` | `kubectl label` din `06-nodes.sh` | `taints: []` în config ca să nu pună NoSchedule |
| `bootstrap-token` | — | token-uri de alăturare cu TTL; tu ai avut certificate direct |
| `addon/coredns`, `addon/kube-proxy` | sărite (`skipPhases`) | Cilium și CoreDNS vin din Git |
| — | `keepalived.sh` | kubeadm nu face VIP; îl presupune (`controlPlaneEndpoint`) |
| — | criptarea Secretelor, audit | kubeadm nu le pornește implicit — un exercițiu: adaugă-le prin `apiServer.extraArgs` și `extraVolumes` |

> [!IMPORTANT]
> **❓ Static pods față de unități systemd**
> Hard way: systemd pornește apiserver-ul. kubeadm: kubelet-ul citește
> `/etc/kubernetes/manifests/*.yaml` și pornește pod-urile direct, fără apiserver (care încă
> nu există — e problema oului și găinii). Le vezi și în `kubectl get pods -n kube-system` ca
> *mirror pods*, dar nu le poți șterge de acolo: sursa de adevăr e fișierul de pe disc. Talos
> face la fel, cu fișierele generate din machine config.

## Partea 3 — platforma, din Git

```bash
# 1. Cheia Sealed Secrets ÎNAINTE de controller: va porni cu ea, nu cu una nouă.
kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ~/sealed-secrets-key.backup.yaml

# 2. Același bootstrap ca în modulul 12. Totul din argocd/apps vine înapoi.
cd ~/k8s-lab && bash bootstrap/bootstrap.sh
kubectl -n argocd get applications -w
```

În timp ce valurile trec, notează ce apare și în ce ordine. Cilium, CoreDNS și ArgoCD vin
din helmfile, restul din Git. BGP-ul revine singur (FRR de pe lab-gw nu a fost atins), deci
`10.10.100.20` și Gateway-ul `10.10.100.10` răspund din nou fără nicio comandă.

### Datele

```bash
kubectl -n longhorn-system get backuptarget              # AVAILABLE: Garage e intact
kubectl -n longhorn-system get backupvolumes.longhorn.io # backup-urile de dinainte de distrugere
```

Restaurează volumele (UI → *Backup* → *Restore*, cu numele inițiale), aplică PV-urile statice,
și verifică datele — modulul 14, pașii 4–5. Prod face asta pentru 7 volume cu `task
longhorn:restore` ([DR.md](../../DR.md), faza 4) și are un set de verificări după: dacă vrei
o temă de casă serioasă, scrie-ți un `dr-verify.sh` pentru lab după modelul
[celui din prod](../../scripts/dr-verify.sh).

- [ ] Opresc cronometrul când `whoami`, `lab-app` și datele restaurate răspund. Timp total: ____ (prod: ~35 min pentru tot, cu VPS)

## Partea 4 — aplicația ta, ca în prod

Ultimul proiect nu are manifeste date. Alege o aplicație reală cu stare (Uptime Kuma, Gitea,
Vaultwarden, Miniflux — ce vrei) și du-o în lab cu tot ce are o aplicație din prod:

- [ ] Director în `apps/`, ApplicationSet-ul o preia
- [ ] Imagine fixată pe digest, urmărită de Renovate
- [ ] `securityContext` care trece de `restricted`, sau o justificare scrisă pentru namespace `baseline`
- [ ] PVC pe Longhorn cu etichetele de backup **și** PV static pentru DR
- [ ] Secretele ei ca SealedSecret
- [ ] HTTPRoute pe Gateway-ul `internal`, cu certificat valid
- [ ] `CiliumNetworkPolicy` default-deny cu excepțiile minime, verificate cu Hubble
- [ ] PDB și probe corecte (liveness fără dependențe)
- [ ] ServiceMonitor (sau o probă blackbox) și o alertă pe care ai provocat-o o dată
- [ ] Trece de `validate` în CI
- [ ] Distruge-i namespace-ul și readu-o, cu date, doar din Git și din backup

## Partea 5 — runbook-ul tău

Scrie `DR.md` pentru lab, în repo-ul `k8s-lab`, după modelul [celui din prod](../../DR.md) și
al [quickstart-ului](../../docs/dr-quickstart.md): ce trebuie să ai înainte, comenzile în
ordine, cât durează fiecare fază, cum arată „sănătos”, și problemele cunoscute pe care le-ai
întâlnit azi. Testul lui: cineva care n-a făcut cursul îl poate urma.

- [ ] `DR.md` scris, împins, și urmat o dată de la capăt fără să improvizezi

## Ce urmează

| Direcție | De ce, după cursul ăsta |
|---|---|
| **Talos în lab** | acum știi ce face; mută lab-ul pe Talos și compară cu tabelul din modulul 08 |
| **CKA, apoi CKS** | ai făcut deja tot ce testează CKA; CKS aprofundează modulul 17 |
| **Cilium mai adânc** | `bpftool prog show`, `cilium-dbg monitor`, Cluster Mesh, BGP cu mai mulți vecini |
| **Cluster API** | clustere ca obiecte Kubernetes — bucla de reconciliere aplicată nodurilor |
| **ArgoCD multi-cluster** | un ArgoCD care gestionează lab-ul și un al doilea cluster |
| **Politici ca cod** | Kyverno: impune semnături, etichete, `restricted` — modulul 17, automat |

## Curățenie

Când nu mai ai nevoie de lab:

```powershell
# pe PC, ca administrator
Get-DnsClientNrptRule | ? Namespace -eq '.lab.merox.dev' | Remove-DnsClientNrptRule -Force
route delete 10.10.0.0; route delete 10.244.0.0
Get-ChildItem Cert:\CurrentUser\Root | ? Subject -like '*k8s-lab root CA*' | Remove-Item
cd learn\lab\infra\terraform; tofu destroy
```

## Întrebări de verificare

Ultimele, fără răspunsuri ascunse. Dacă le poți răspunde cu voce tare, fără notițe, ai
terminat cursul.

1. Un pod nu pornește. Spune, în ordine, primele cinci comenzi pe care le rulezi și de ce.
2. Desenează drumul unui request de pe telefon până la un pod din prod, cu fiecare traducere de adresă.
3. Ce se întâmplă, secundă cu secundă, când nodul care deține VIP-ul API-ului moare?
4. De ce prod poate trăi fără backup la etcd, și ce ar trebui să se schimbe ca să nu mai poată?
5. Care sunt cele trei chei fără de care prod nu se mai poate reconstrui, și ce protejează fiecare?
6. Revino la cele 5 lucruri din repo pe care nu le puteai explica în modulul 00. Explică-le acum.
