# Linux esențial pentru infrastructură

Kubernetes nu face nimic magic pe un nod. Kubelet-ul pornește procese, le pune
în cgroups și namespaces, le trimite semnale și le citește codul de ieșire.
etcd, apiserver-ul și kubelet-ul sunt, în hard way, servicii systemd ca oricare
altele. Dacă știi Linux la nivelul ăsta, poți depana orice nod.

Laboratorul îl faci pe **lab-gw** (și pe un nod unde se cere).

## Procese: PID, părinte, PID 1

Orice proces are un **PID** și un **părinte** (PPID). Un proces nou se naște în
doi pași: `fork()` (copie a părintelui) și `exec()` (înlocuiește programul). Când
un proces moare, rămâne o intrare minusculă — un *zombie* — până când părintele
îi citește codul de ieșire (`wait()`).

**PID 1** e special: e rădăcina arborelui și **adoptă orfanii** — orice proces al
cărui părinte a murit devine copilul lui PID 1, care trebuie să-i culeagă. Pe
Ubuntu, PID 1 e `systemd`. Pe Talos, e `machined` — fără systemd, fără shell.

```bash
ps -o pid,ppid,stat,cmd -p 1
pstree -p | head -20
ps -eo pid,ppid,stat,cmd | awk '$3 ~ /Z/'     # zombies, de obicei niciunul
```

> [!IMPORTANT]
> **❓ De ce contează pentru containere?**
> Într-un container, procesul tău **este** PID 1 (în namespace-ul lui de PID-uri,
> modulul 04). Două consecințe: (1) dacă pornește copii și nu-i culege, se adună
> zombies; (2) kernelul **nu aplică acțiunea implicită** a semnalelor pentru PID 1
> — un SIGTERM pe care programul nu-l tratează explicit e pur și simplu ignorat.
> Kubelet-ul trimite SIGTERM, așteaptă `terminationGracePeriodSeconds`, apoi
> SIGKILL. O aplicație care nu tratează SIGTERM moare mereu „urât”, după 30 de
> secunde. De aceea [lab-app](../lab/k8s-lab/src/lab-app/main.go) prinde
> SIGTERM explicit.

## Semnale

| Semnal | Nr. | Implicit | Cine îl trimite în Kubernetes |
|---|---|---|---|
| `SIGTERM` | 15 | termină (poate fi prins) | kubelet, la ștergerea unui pod |
| `SIGKILL` | 9 | moare imediat (nu poate fi prins) | kubelet, după grace period; OOM killer |
| `SIGHUP` | 1 | termină; convenție: „recitește config-ul” | `systemctl reload` la multe servicii |
| `SIGINT` | 2 | termină | Ctrl+C |

```bash
cat > /tmp/trap.sh <<'EOF'
#!/bin/bash
trap 'echo "SIGTERM primit, închid curat"; exit 0' TERM
echo "PID $$, aștept"; while true; do sleep 1; done
EOF
bash /tmp/trap.sh &  sleep 1;  kill -TERM %1;  wait
```

Un cod de ieșire **137** înseamnă 128 + 9: procesul a murit de SIGKILL. În
Kubernetes îl vei vedea lângă `OOMKilled` (modulul 09) — kernelul a omorât
procesul pentru că a depășit limita de memorie.

## systemd: servicii, dependențe, timere

systemd pornește și supraveghează serviciile descrise în **unit files**. Un unit
are trei secțiuni: `[Unit]` (ce e, după ce pornește), `[Service]` (cum rulează),
`[Install]` (ce target îl trage după el la boot).

```ini
[Unit]
Description=…
After=network-online.target      # ordine: pornește după
Wants=network-online.target      # dependență slabă: cere-l, dar nu muri fără el
Requires=containerd.service      # dependență tare: moare dacă moare containerd

[Service]
Type=notify                      # „gata” = când procesul anunță el însuși
ExecStart=/usr/local/bin/etcd …
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target       # systemctl enable → pornește la boot
```

| `Type=` | systemd consideră serviciul pornit când… | Folosit de |
|---|---|---|
| `simple` | procesul a fost lansat | majoritatea |
| `notify` | procesul trimite `READY=1` (sd_notify) | etcd, containerd |
| `oneshot` | procesul s-a terminat cu succes | scripturi, timere |

> [!NOTE]
> **🏠 Unitățile din prod**
> [restic-retention.service](../../vps/roles/restic_rest_server/files/restic-retention.service)
> e un `oneshot` pornit de un [timer](../../vps/roles/restic_rest_server/files/restic-retention.timer)
> cu `OnCalendar`, `Persistent=true` (rulează la boot dacă a ratat ora) și
> `RandomizedDelaySec`. [cpu-power.service](../../proxmox/pve-1/etc/systemd/system/cpu-power.service)
> e un `oneshot` cu `RemainAfterExit=yes`: scrie în sysfs la boot și rămâne
> „active”, pentru că sysfs e stare în RAM și se pierde la repornire. Comentariul
> lui despre ordinea scrierilor e o lecție despre kernel în sine.

> [!TIP]
> **🧠 Analogie: systemd e dispeceratul unei firme de taxi**
> Fiecare unit e o cursă programată: „pleacă după ce s-a deschis drumul”
> (`After=`), „dacă mașina se strică, trimite alta în 5 secunde” (`Restart=`),
> „cursa e confirmată când șoferul sună înapoi” (`Type=notify`). Kubelet-ul face
> exact același lucru, doar că pentru containere, și cu un dispecer central
> (apiserver-ul) care îi spune ce curse să aibă.

`Type=notify` are o consecință pe care o vei vedea în modulul 06: un membru etcd
nu e „ready” fără quorum. Pornit singur, `systemctl start etcd` așteaptă la
nesfârșit. De aceea [04-etcd.sh](../lab/hardway/04-etcd.sh) le pornește pe toate
trei odată, cu `--no-block`.

## Jurnale: journalctl

```bash
journalctl -u nftables                 # un serviciu
journalctl -u ssh -f                   # urmărește în timp real
journalctl -b -p err                   # erorile de la ultimul boot
journalctl --since "10 min ago" -o short-precise
systemctl status <unit>                # starea + ultimele 10 linii de jurnal
systemctl list-units --failed
```

Ordinea de depanare a unui serviciu, de fiecare dată: `systemctl status` (rulează?
cu ce cod a ieșit?) → `journalctl -u … -n 50` (de ce?) → rulezi `ExecStart` de
mână, ca root, să vezi eroarea direct.

## Fișiere: unde stă ce

| Cale | Conține | În curs |
|---|---|---|
| `/etc` | configurație | `/etc/kubernetes`, `/etc/etcd`, `/etc/containerd` |
| `/var/lib` | starea persistentă a serviciilor | `/var/lib/etcd`, `/var/lib/kubelet`, `/var/lib/containerd` |
| `/var/log` | jurnale scrise în fișiere | `/var/log/kubernetes/audit.log` |
| `/run` | stare de rulare, în RAM | `/run/containerd/containerd.sock` |
| `/usr/local/bin` | binare instalate de tine, nu de apt | toate binarele Kubernetes din hard way |
| `/proc`, `/sys` | interfața kernelului ca fișiere | sysctl, cgroups, informații despre procese |

### Permisiuni

```
-rw------- 1 root root  227 … apiserver.key      600: doar root citește/scrie
-rw-r--r-- 1 root root  891 … apiserver.crt      644: oricine citește
drwx------ 3 etcd etcd 4096 … /var/lib/etcd      700: doar proprietarul intră
```

Trei triplete `rwx` — proprietar, grup, ceilalți — scrise și în octal (r=4, w=2,
x=1). Cheile private sunt **600**, certificatele **644**: un certificat e public
prin definiție, cheia lui nu. `umask 077` din [02-pki.sh](../lab/hardway/02-pki.sh)
face ca orice fișier nou creat de script să fie privat implicit.

## /proc și /sys: kernelul ca fișiere

```bash
cat /proc/sys/net/ipv4/ip_forward       # = sysctl net.ipv4.ip_forward
ls /proc/$$/ns                          # namespace-urile shell-ului tău (modulul 04)
cat /proc/$$/cgroup                     # cgroup-ul lui
cat /proc/meminfo | head -5
ls /sys/fs/cgroup                       # arborele cgroup v2
```

Un `sysctl` e doar o scriere în `/proc/sys`. Fișierele din `/etc/sysctl.d/` sunt
reaplicate la fiecare boot de `systemd-sysctl` — de asta
[01-prepare-nodes.sh](../lab/hardway/01-prepare-nodes.sh) le scrie acolo, nu le
setează doar cu `sysctl -w`.

> [!NOTE]
> **🏠 Sysctl-urile din prod**
> [machine-sysctls.yaml](../../talos/patches/global/machine-sysctls.yaml) setează
> BBR ca algoritm de congestie TCP, cu măsurătoarea care l-a justificat: 30 Mbps cu
> CUBIC față de 103 Mbps cu BBR pe tunelul spre VPS (RTT 165 ms). Laboratorul
> copiază aceleași valori. Observă nota: pod-urile *moștenesc* sysctl-urile de rețea
> la crearea namespace-ului, deci cele existente au nevoie de restart.

## Unelte de depanare pe care le vei folosi zilnic

| Întrebare | Comandă |
|---|---|
| Cine ascultă pe ce port? | `sudo ss -tlnp` |
| Ce fișiere/socket-uri are deschise un proces? | `sudo lsof -p <pid>` |
| Ce face procesul acum (syscalls)? | `sudo strace -f -p <pid>` |
| Cine consumă CPU/memorie? | `top`, `htop`, `ps aux --sort=-rss \| head` |
| Ce a zis kernelul (OOM, disc, rețea)? | `sudo dmesg -T \| tail -50` |
| Cât disc? Unde s-a dus? | `df -h`, `sudo du -xh --max-depth=1 / \| sort -h` |
| Mai sunt inode-uri/descriptori? | `df -i`, `cat /proc/sys/fs/file-nr` |

## Laborator

Pe lab-gw.

### 1. Un serviciu și un timer, de la zero

Scrie un „heartbeat” — aceeași idee ca
[heartbeat-ping.sh](../../proxmox/pve-1/scripts/heartbeat-ping.sh) din prod, doar
că local:

```bash
sudo tee /usr/local/bin/lab-heartbeat >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
echo "$(date -Is) $(hostname) up $(cut -d' ' -f1 /proc/uptime)s" >> /var/lib/lab-heartbeat/log
EOF
sudo chmod 755 /usr/local/bin/lab-heartbeat

sudo tee /etc/systemd/system/lab-heartbeat.service >/dev/null <<'EOF'
[Unit]
Description=Lab heartbeat

[Service]
Type=oneshot
StateDirectory=lab-heartbeat
ExecStart=/usr/local/bin/lab-heartbeat
EOF

sudo tee /etc/systemd/system/lab-heartbeat.timer >/dev/null <<'EOF'
[Unit]
Description=Lab heartbeat, every minute

[Timer]
OnCalendar=*:*:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now lab-heartbeat.timer
systemctl list-timers lab-heartbeat.timer
```

`StateDirectory=` creează `/var/lib/lab-heartbeat` cu proprietarul corect — systemd
face asta pentru tine.

### 2. Un serviciu care cade

```bash
sudo tee /etc/systemd/system/lab-crash.service >/dev/null <<'EOF'
[Unit]
Description=Crashes on purpose
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
ExecStart=/bin/sh -c 'echo pornesc; sleep 2; exit 3'
Restart=on-failure
RestartSec=2
EOF
sudo systemctl daemon-reload && sudo systemctl start lab-crash
watch -n1 systemctl status lab-crash --no-pager     # Ctrl+C după ~15 s
journalctl -u lab-crash --no-pager | tail
```

După trei eșecuri în 60 de secunde, systemd renunță: *start request repeated too
quickly*. E exact ce face kubelet-ul cu `CrashLoopBackOff`, doar că kubelet-ul nu
renunță niciodată — dublează pauza, până la un plafon.

> [!NOTE]
> **🏠 Plafonul CrashLoopBackOff din prod**
> [machine-kubelet.yaml](../../talos/patches/global/machine-kubelet.yaml) scade
> plafonul de la 5 minute la 60 de secunde (`maxContainerRestartPeriod`), pentru ca
> aplicațiile să revină într-un minut după ce NAS-ul sau Postgres-ul revin.

## Taskuri

- [ ] Pe un nod, `pstree -p | head` — cine e PID 1, și ce procese sunt copiii lui direcți?
- [ ] Rulează scriptul cu `trap` și apoi încă o dată cu `kill -KILL` în loc de `-TERM`; explică diferența
- [ ] Creează `lab-heartbeat.service` + `.timer`; după 3 minute ai 3 linii în log
- [ ] Explică ce ar schimba `Persistent=true` dacă lab-gw ar fi oprit la ora unei rulări
- [ ] Creează `lab-crash.service` și reprodu „start request repeated too quickly”; apoi `systemctl reset-failed lab-crash`
- [ ] `sudo ss -tlnp` pe lab-gw: identifică fiecare port care ascultă și procesul lui
- [ ] Găsește în `/proc` namespace-urile și cgroup-ul shell-ului tău
- [ ] Citește [cpu-power.service](../../proxmox/pve-1/etc/systemd/system/cpu-power.service) și explică de ce e `oneshot` + `RemainAfterExit`
- [ ] Șterge cele două unități de test (`disable --now`, rm, `daemon-reload`)

## Întrebări de verificare

<details>
<summary>Un pod are restartCount 12 și ultimul exit code 137. Ce s-a întâmplat, cel mai probabil?</summary>

137 = 128 + 9: procesul a primit SIGKILL. Cele două cauze uzuale: OOM killer-ul
kernelului (a depășit `limits.memory` — `kubectl describe pod` arată
`Reason: OOMKilled`) sau kubelet-ul după expirarea grace period-ului (procesul n-a
ieșit la SIGTERM). Dacă e OOM, `dmesg` pe nod are linia „Memory cgroup out of memory”.
</details>

<details>
<summary>De ce `After=` nu ajunge ca să garantezi că un serviciu dependent rulează?</summary>

`After=` e doar **ordine**: dacă ambele sunt pornite, X pornește după Y. Nu cere
ca Y să pornească deloc. Pentru asta e nevoie de `Wants=` (cere-l) sau
`Requires=` (cere-l și oprește-mă dacă el cade). De obicei le pui pe amândouă, ca
`containerd.service` în unit-ul kubelet-ului din [06-nodes.sh](../lab/hardway/06-nodes.sh).
</details>

<details>
<summary>Talos nu are systemd. Cine face treaba lui acolo?</summary>

`machined`, PID 1 pe Talos. Pornește și supraveghează serviciile sistemului (etcd,
kubelet, containerd, apid) dintr-o configurație declarativă (machine config), iar
tu vorbești cu el doar prin API (`talosctl`). Nu există shell, SSH sau unit files —
de asta în prod nu „repornești kubelet-ul”, ci aplici un config.
</details>
