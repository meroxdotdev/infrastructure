# PKI și TLS fără mistere

Un cluster Kubernetes făcut de mână are în jur de 25 de certificate. Fiecare
eroare de tipul `x509: …` pe care o vei vedea în modulele următoare se rezolvă în
cinci minute dacă știi ce verifică cine. Modulul ăsta te pregătește exact pentru asta.

## Ideea, în trei propoziții

1. O **pereche de chei**: ce semnezi cu cheia privată se verifică cu cea publică.
   Publica o dai oricui; privata nu părăsește niciodată mașina care o folosește.
2. Un **certificat** e o cheie publică plus o identitate („sunt `kube-apiserver`,
   adresele mele sunt …”), **semnate** de cineva.
3. O **autoritate de certificare (CA)** e acel cineva. Ai încredere în CA → ai
   încredere în tot ce a semnat ea.

> [!TIP]
> **🧠 Analogie: pașaportul**
> Certificatul e pașaportul: poza ta (cheia publică), numele (Subject), unde ai voie
> să intri (SAN, Key Usage), data expirării, și ștampila statului emitent
> (semnătura CA). Ofițerul de la graniță (cel care verifică) nu te cunoaște pe tine —
> cunoaște ștampilele statelor în care are încredere (trust store-ul). Un pașaport
> perfect, dar de la un stat necunoscut, e respins: *signed by unknown authority*.
> mTLS e o graniță la care **amândoi** își arată pașapoartele.

## Ce conține un certificat X.509

```bash
openssl x509 -in cert.crt -noout -text
```

| Câmp | Ce înseamnă | Cine îl verifică |
|---|---|---|
| **Subject** (`CN`, `O`) | cine ești. Kubernetes citește `CN` ca nume de utilizator și fiecare `O` ca grup | apiserver-ul, la autentificare |
| **Issuer** | cine a semnat | clientul: îl caută în trust store |
| **Validity** (`notBefore`, `notAfter`) | intervalul de valabilitate | toată lumea — de asta contează ora sincronizată |
| **Subject Alternative Name** | numele și IP-urile pentru care certificatul e valabil | clientul compară cu adresa pe care a apelat-o |
| **Basic Constraints** `CA:TRUE/FALSE` | poate semna alte certificate? | cel care verifică lanțul |
| **Key Usage** / **Extended Key Usage** | `serverAuth`, `clientAuth` — la ce e bun | ambele părți |

> [!IMPORTANT]
> **❓ De ce SAN și nu CN pentru nume?**
> Istoric, numele serverului stătea în `CN`. Din 2017, browserele și Go (deci tot
> Kubernetes) **ignoră complet CN-ul** pentru verificarea serverului și se uită doar
> la SAN. Un certificat de server fără SAN e respins, oricât de corect ar fi CN-ul.
> Pentru certificatele **client**, în schimb, Kubernetes citește CN-ul ca identitate.
> Același câmp, două roluri — o sursă clasică de confuzie.

## TLS și mTLS, pas cu pas

```mermaid
sequenceDiagram
  participant C as Client (kubectl)
  participant S as Server (kube-apiserver)
  C->>S: ClientHello
  S->>C: certificatul serverului (+ cere certificat client)
  Note over C: verifică: semnat de CA-ul meu?<br/>SAN conține adresa apelată?<br/>în termen? EKU serverAuth?
  C->>S: certificatul clientului + dovada că deține cheia
  Note over S: verifică: semnat de --client-ca-file?<br/>EKU clientAuth?<br/>→ user = CN, grupuri = O
  S-->>C: canal criptat; request-ul e autentificat ca „admin”
```

TLS simplu: doar serverul își dovedește identitatea (HTTPS obișnuit). **mTLS**
(mutual TLS): și clientul. Kubernetes folosește mTLS aproape peste tot: kubectl →
apiserver, apiserver → etcd, apiserver → kubelet, membru etcd → membru etcd.

## Laborator — un CA, un server, un client

Pe lab-gw, într-un director de lucru:

```bash
mkdir -p ~/pki-lab && cd ~/pki-lab

# 1. CA-ul: cheie + certificat auto-semnat, CA:TRUE.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 365 -subj "/CN=pki-lab-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.crt

# 2. Un certificat de server pentru „lab-gw” și 127.0.0.1.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out server.key
openssl req -new -key server.key -subj "/CN=demo-server" -out server.csr
cat > server.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:lab-gw,DNS:localhost,IP:127.0.0.1
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 30 -sha256 -extfile server.ext -out server.crt

# 3. Un certificat de client: identitatea e în CN și O, exact ca în Kubernetes.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out client.key
openssl req -new -key client.key -subj "/O=developers/CN=ana" -out client.csr
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > client.ext
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 30 -sha256 -extfile client.ext -out client.crt

openssl x509 -in server.crt -noout -subject -issuer -dates -ext subjectAltName
openssl verify -CAfile ca.crt server.crt client.crt
```

Pornește un server TLS care **cere** certificat de client (`-Verify`):

```bash
openssl s_server -accept 8443 -cert server.crt -key server.key -CAfile ca.crt -Verify 1 -www &
```

Și provoacă, pe rând, fiecare eroare pe care o vei întâlni în cluster:

```bash
# ✗ nu am încredere în CA: „unable to get local issuer certificate”
curl https://localhost:8443/
# ✗ CA bun, dar fără certificat client: serverul închide handshake-ul
curl --cacert ca.crt https://localhost:8443/
# ✗ CA bun, certificat client bun, dar un nume care nu e în SAN
curl --cacert ca.crt --cert client.crt --key client.key https://10.10.0.1:8443/
# ✓ totul corect — mTLS
curl --cacert ca.crt --cert client.crt --key client.key https://localhost:8443/ | head -5
kill %1
```

Ultimul `curl` arată în pagina serverului `subject=O=developers, CN=ana`: serverul
știe cine ești din certificat. Exact asta face apiserver-ul cu `admin.kubeconfig`.

## Erorile, traduse

| Mesaj | Ce înseamnă de fapt | Unde verifici |
|---|---|---|
| `x509: certificate signed by unknown authority` | clientul nu are CA-ul care a semnat certificatul serverului | `certificate-authority-data` din kubeconfig; `--cacert` |
| `x509: certificate is valid for A, B, not C` | ai apelat serverul pe o adresă absentă din SAN | `openssl x509 -ext subjectAltName`; adaugă SAN-ul și re-emite |
| `x509: certificate has expired or is not yet valid` | în afara intervalului — sau ceasul unei mașini e greșit | `-dates`; `timedatectl` pe ambele mașini |
| `remote error: tls: bad certificate` | serverul a respins certificatul **clientului** | CA-ul de clienți al serverului (`--client-ca-file`, `--trusted-ca-file`) |
| `Unauthorized` (401) | TLS a mers, dar identitatea nu e recunoscută | CN/O în certificatul client |
| `Forbidden` (403) | identitatea e recunoscută, dar RBAC nu permite | `kubectl auth can-i` (modulul 17) |

> [!NOTE]
> **🏠 Eroarea din runbook-ul prod**
> [docs/operations.md](../../docs/operations.md) avertizează: un `talosctl` rulat în
> afara `task` cade pe `~/.talos/config`, un config vechi *al cărui CA nu se mai
> potrivește*, și eșuează cu `x509: certificate signed by unknown authority`. Prima
> linie din tabelul de mai sus, în viața reală: clusterul e bun, clientul are
> încredere în CA-ul greșit.

## RSA sau ECDSA, și cât să trăiască un certificat

Laboratorul folosește **ECDSA P-256**: chei mici, semnături rapide, suportate de
toate componentele. RSA 2048 e alternativa clasică (kubeadm o folosește implicit).

Durata e un compromis: un certificat scurt limitează paguba unei chei furate, dar
trebuie reînnoit automat — altfel expiră peste noapte. Certificatele hard way au un
an (`-days 365` în [02-pki.sh](../lab/hardway/02-pki.sh)): vei vedea în modulul 18
ce înseamnă să le rotești.

> [!NOTE]
> **🏠 Prod folosește certificate de 6 zile**
> [clusterissuer.yaml](../../kubernetes/apps/cert-manager/cert-manager/app/clusterissuer.yaml)
> are `profile: shortlived` — profilul Let's Encrypt cu certificate de aproximativ
> 6 zile. E sigur doar pentru că cert-manager le reînnoiește singur, și există o
> alertă care ar suna dacă n-ar face-o (`cert-rules` în
> [kube-prometheus-stack](../../kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml)).

## Taskuri

- [ ] Creează CA-ul, certificatul de server și cel de client din laborator
- [ ] Citește `server.crt` cu `openssl x509 -noout -text` și găsește SAN, EKU, Basic Constraints
- [ ] Reprodu cele trei erori cu `curl`, apoi conexiunea mTLS reușită
- [ ] Emite un al doilea certificat de server **fără** SAN și arată că `curl` îl respinge chiar dacă CN-ul e corect
- [ ] Semnează un certificat de client cu un **alt** CA și arată ce eroare dă serverul
- [ ] `openssl x509 -in server.crt -noout -checkend 2592000` — explică rezultatul pentru 30 de zile
- [ ] Explică în notițe de ce cheia CA-ului nu trebuie să ajungă niciodată pe un nod worker
- [ ] Curăță: `rm -rf ~/pki-lab`

## Întrebări de verificare

<details>
<summary>Apiserver-ul primește un certificat client cu `CN=system:node:k8s-2` și `O=system:nodes`. Ce înseamnă pentru el?</summary>

Utilizatorul `system:node:k8s-2`, în grupul `system:nodes`. Autorizatorul **Node**
recunoaște exact forma asta și îi permite kubelet-ului de pe k8s-2 să citească și
să modifice doar ce ține de nodul lui (pod-urile programate pe el, secretele lor).
Asta e tot „login-ul” unui kubelet: un certificat cu un nume bine ales.
</details>

<details>
<summary>De ce ai avea trei CA-uri separate (Kubernetes, etcd, front-proxy) în loc de unul?</summary>

Pentru că încrederea se dă **pe CA**. etcd acceptă orice client cu un certificat
semnat de CA-ul pe care îl are configurat. Dacă etcd ar avea încredere în CA-ul
Kubernetes, orice certificat emis pentru orice kubelet sau utilizator ar putea
vorbi direct cu baza de date a clusterului, ocolind RBAC. Un CA separat pentru
etcd înseamnă: doar apiserver-ul (și tu, cu `etcdctl`) primește un certificat de
la el.
</details>

<details>
<summary>Un certificat valid apare „expirat” doar pe un nod. Ce verifici?</summary>

Ceasul nodului: `timedatectl`. Validitatea e comparată cu ora locală a celui care
verifică. Un nod rămas în urmă cu o zi vede certificatele emise azi ca „not yet
valid”; unul înainte vede certificatele aproape de expirare ca expirate. De aceea
prod fixează serverele NTP în [machine-time.yaml](../../talos/patches/global/machine-time.yaml).
</details>
