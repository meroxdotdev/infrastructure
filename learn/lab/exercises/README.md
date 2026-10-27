# Exerciții de depanare (modulul 18)

Fiecare fișier e un workload stricat într-un singur fel. Aplică-l, găsește
defectul **folosind doar ce îți arată clusterul** (nu citi YAML-ul până nu ai o
ipoteză), repară-l, apoi notează în modulul 18 ce comandă ți-a dat răspunsul.

```bash
kubectl create namespace drill
kubectl -n drill apply -f 01-crashloop.yaml
# … depanezi …
kubectl delete namespace drill     # la final
```

| Fișier | Simptom pe care îl vei vedea |
|---|---|
| `01-crashloop.yaml` | Pod în `CrashLoopBackOff` |
| `02-no-endpoints.yaml` | Service-ul există, `curl` dă timeout |
| `03-not-ready.yaml` | Pod `Running`, dar `0/1 READY` |
| `04-oom.yaml` | Restart-uri, `Last State: Terminated` |
| `05-pending.yaml` | Pod `Pending` la nesfârșit |
| `06-netpol.yaml` | Un pod nu mai poate vorbi cu altul după o politică |
| `07-drain.yaml` | `kubectl drain` nu se termină niciodată |
| `08-image.yaml` | `ImagePullBackOff` |

Metoda, de fiecare dată: **status → events → logs → describe → hubble/tcpdump**,
de la general la specific. Nu sări direct la loguri.
