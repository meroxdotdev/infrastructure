# Glosar

Termenii cursului, pe scurt. Numărul din paranteză e modulul care îi explică pe larg.

## Linux și rețea

| Termen | Pe scurt |
|---|---|
| **PID 1** | primul proces; adoptă orfanii și nu primește acțiunea implicită a semnalelor (02) |
| **SIGTERM / SIGKILL** | „oprește-te, te rog” / „mori acum”; kubelet-ul le trimite în ordinea asta (02) |
| **systemd unit** | descrierea unui serviciu: cum pornește, după ce, ce face dacă moare (02) |
| **sysctl** | parametru al kernelului, scris în `/proc/sys` (02) |
| **CIDR** | notația unui bloc de adrese: `10.244.0.0/16` = primii 16 biți fixați (03) |
| **longest prefix match** | dintre rutele care se potrivesc, câștigă cea mai specifică (03) |
| **ARP / ARP gratuit** | „cine are IP-ul X?” / „X e la mine acum” — mută un VIP (03) |
| **bridge** | switch virtual în kernel (03) |
| **network namespace** | o stivă de rețea separată: interfețe, rute, firewall proprii (03, 04) |
| **veth** | cablu virtual cu două capete; un capăt în pod, unul pe host (03) |
| **NAT / masquerade** | rescrierea sursei (sau destinației) unui pachet; conntrack ține minte traducerea (03) |
| **conntrack** | tabela de conexiuni a kernelului; face ca răspunsurile să treacă (03) |
| **netfilter / nftables** | cadrul de filtrare din kernel / sintaxa lui modernă (01, 03) |
| **rutare asimetrică** | dus pe un drum, întors pe altul — firewall-urile stateful o aruncă (01) |
| **MTU** | dimensiunea maximă a unui pachet pe o legătură; tunelurile o micșorează (03) |

## Containere

| Termen | Pe scurt |
|---|---|
| **container** | un proces cu namespaces, cgroups și alt rootfs — nu o mașină virtuală (04) |
| **cgroup v2** | limitele de resurse ale unui grup de procese (`memory.max`, `cpu.max`) (04) |
| **overlayfs** | straturi read-only + un strat de scriere; baza imaginilor (04) |
| **OCI** | standardele pentru imagini și runtime-uri de containere (04) |
| **runc** | runtime-ul de jos: face syscall-urile care creează containerul (04) |
| **containerd** | gestionează imagini și containere; servește CRI pentru kubelet (04, 08) |
| **CRI** | interfața gRPC dintre kubelet și runtime (04) |
| **pause container** | containerul care ține namespace-urile unui pod (04) |
| **digest** | hash-ul sha256 al conținutului unei imagini; imuabil, spre deosebire de tag (16) |
| **distroless** | imagine fără shell și manager de pachete — doar aplicația (04, 16) |

## PKI

| Termen | Pe scurt |
|---|---|
| **CA** | autoritatea care semnează certificate; ai încredere în ea → ai încredere în ce semnează (05) |
| **SAN** | numele și IP-urile pentru care e valabil un certificat de server (05) |
| **EKU** | la ce e bun certificatul: `serverAuth`, `clientAuth` (05) |
| **mTLS** | TLS în care și clientul își prezintă certificatul (05) |
| **CSR** | cererea de certificat: cheia publică + identitatea, semnate cu cheia privată (05, 17) |
| **system:masters** | grupul care ocolește RBAC; certificatele cu el nu pot fi revocate (17) |

## Kubernetes — componente

| Termen | Pe scurt |
|---|---|
| **etcd** | baza de date cheie-valoare cu toată starea clusterului; Raft, quorum (06) |
| **Raft / quorum** | algoritmul de consens / majoritatea necesară pentru o scriere (06) |
| **kube-apiserver** | singura poartă spre etcd: autentifică, autorizează, validează (07) |
| **admission** | pasul în care o cerere poate fi modificată sau refuzată (PodSecurity, webhooks) (07) |
| **kube-scheduler** | alege nodul fiecărui pod nou (07) |
| **kube-controller-manager** | buclele de control de bază: Deployment, Node, EndpointSlice… (07) |
| **leader election / Lease** | un singur controller activ; ceilalți așteaptă lease-ul (07) |
| **VIP / VRRP** | o adresă care se mută între noduri / protocolul care o mută (07) |
| **KubePrism** | load balancer-ul local al Talos pe `127.0.0.1:7445`, spre toate apiserver-ele (07) |
| **kubelet** | agentul de pe nod: pornește pod-urile și raportează (08) |
| **static pod** | pod pornit de kubelet dintr-un fișier, fără apiserver (19) |
| **CNI** | contractul prin care runtime-ul cere rețea pentru un pod (08) |
| **eBPF** | programe încărcate în kernel; Cilium face rutare, NAT, LB și politici cu ele (08, 10) |
| **kube-proxy replacement** | Cilium implementează Services în eBPF, fără iptables (08, 10) |

## Kubernetes — obiecte

| Termen | Pe scurt |
|---|---|
| **spec / status** | ce vrei / ce este (09) |
| **reconciliere** | bucla observă → compară → acționează; baza a tot (09) |
| **ownerReference** | „m-a creat X”; ștergi X, sunt șters și eu (09) |
| **finalizer** | „nu mă șterge până nu termin curățenia” (09, 12) |
| **Deployment / ReplicaSet** | replici interschimbabile / setul concret pentru un template (09) |
| **StatefulSet** | replici cu nume și disc stabile (09) |
| **DaemonSet** | un pod pe fiecare nod (09) |
| **readiness / liveness** | „trimite-mi trafic” / „repornește-mă” (09) |
| **requests / limits** | ce rezervă scheduler-ul / plafonul impus de kernel (09) |
| **QoS class** | Guaranteed / Burstable / BestEffort — ordinea evacuării (09) |
| **taint / toleration** | „nu primesc pe nimeni” / „eu am voie” (09) |
| **PDB** | câte pod-uri pot lipsi deodată la o evacuare voluntară (09, 18) |
| **Service / EndpointSlice** | un IP stabil / lista pod-urilor din spatele lui (10) |
| **ClusterIP / NodePort / LoadBalancer** | intern / port pe fiecare nod / IP extern (10) |
| **externalTrafficPolicy** | `Cluster` (oriunde, SNAT) sau `Local` (doar pod-uri locale, IP-ul real) (10) |
| **Gateway / HTTPRoute** | ce ascultă și cu ce certificat / unde trimite un hostname (10) |
| **NetworkPolicy** | cine are voie să vorbească cu cine; din momentul selecției, default deny (10) |
| **PV / PVC / StorageClass** | volumul / cererea / rețeta (14) |
| **CSI** | contractul prin care Kubernetes vorbește cu un sistem de stocare (14) |
| **CRD** | un tip nou de obiect, adăugat de un operator (Certificate, Application…) (11) |
| **RBAC** | Role/ClusterRole + Binding: cine poate ce, doar aditiv (17) |
| **ServiceAccount** | identitatea unui pod față de API; token JWT legat de pod (17) |
| **Pod Security Admission** | profilele privileged / baseline / restricted, pe namespace (17) |

## Rețea avansată

| Termen | Pe scurt |
|---|---|
| **BGP** | protocolul prin care rețelele își anunță prefixele (10) |
| **AS / ASN** | o rețea cu politică proprie / numărul ei (10) |
| **eBGP** | BGP între AS-uri diferite — nodurile (65001) și lab-gw (65000) (10) |
| **ECMP** | același prefix pe mai multe drumuri egale; traficul se împarte (10) |
| **route-map / prefix-list** | filtrele unei sesiuni BGP (10) |
| **L2 announcements** | Cilium răspunde la ARP pentru IP-uri LoadBalancer — ce face prod (10) |
| **LB IPAM** | alocarea IP-urilor LoadBalancer din pool-uri (10) |
| **SNAT / DSR** | răspunsul trece înapoi prin nodul de intrare / pleacă direct de la backend (10) |
| **Hubble** | observabilitatea Cilium: fiecare flux, cu verdict (10) |
| **ndots** | sub câte puncte un nume e încercat întâi cu domeniile de căutare (10) |

## Livrare și operare

| Termen | Pe scurt |
|---|---|
| **IaC** | infrastructură descrisă în cod (Terraform/OpenTofu) (01) |
| **state (Terraform)** | ce știe Terraform că a creat; secret, niciodată în Git (01) |
| **cloud-init** | configurare la primul boot dintr-o imagine cloud (01) |
| **Helm chart / release** | pachet de șabloane / o instalare a lui, cu istoric (11) |
| **Kustomize overlay / component** | patch-uri peste o bază / o bucată reutilizabilă (11) |
| **GitOps** | starea dorită în Git, trasă și reconciliată continuu de un agent (12) |
| **app of apps** | o Application care creează alte Application-uri (12) |
| **sync wave** | ordinea de aplicare în ArgoCD — echivalentul `dependsOn` (12) |
| **selfHeal / prune** | corectează abaterile / șterge ce nu mai e în Git (12) |
| **ApplicationSet** | generator de Application-uri (din directoare, liste, clustere) (12) |
| **SOPS / age** | criptarea valorilor în fișiere, cu chei age — prod (13) |
| **Sealed Secrets** | secrete criptate pentru un controller din cluster — lab (13) |
| **ACME / DNS-01** | protocolul Let's Encrypt / proba prin record TXT (13) |
| **split DNS** | același domeniu, răspunsuri diferite în funcție de cine întreabă (13) |
| **snapshot / backup** | copie locală, rapidă / copie în afara clusterului, durabilă (14) |
| **PromQL** | limbajul de interogare Prometheus (15) |
| **ServiceMonitor** | „scrape Service-urile astea” pentru Prometheus Operator (15) |
| **Watchdog / dead man's switch** | alertă mereu activă; tăcerea ei e alarma (15) |
| **keyless signing** | semnătură cu identitatea OIDC a workflow-ului, fără cheie de păstrat (16) |
| **Renovate** | bot care deschide PR-uri pentru dependențe fixate (16) |
| **version skew** | cât de diferite pot fi versiunile componentelor; kubelet niciodată mai nou (18) |
| **drain / cordon** | evacuează pod-urile / oprește programarea pe un nod (18) |
| **tier 1/2/3** | clasificarea datelor după cât costă pierderea lor — din `architecture.md` (14, 18) |
