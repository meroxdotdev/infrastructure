# HEARTBEAT.md — Infra Agent

Runs twice daily: 08:00 UTC (11:00 EEST) și 20:00 UTC (23:00 EEST).

## ⛔ FILE OWNERSHIP — READ BEFORE WRITING ANYTHING

| File | Owner | Allowed to write? |
|------|-------|-------------------|
| `/srv/dashboard/data/infra.json` | bash script `update-infra.sh` (runs every 5 min) | **NO — never** |
| `/srv/dashboard/data/agents.json` | all agents | YES — only your `infra` key |
| `/srv/dashboard/data/infra-extended.json` | infra AI agent | YES — you own this |

**NEVER write `infra.json`.** The bash script overwrites it every 5 minutes with rich data. If you write it, you corrupt the dashboard until the next cron tick.

## Checks to run

```bash
# 1. Cluster health
kubectl get nodes --no-headers
kubectl get pods -A --no-headers | grep -v -E "Running|Completed|Succeeded"

# 2. FluxCD (folosește kubectl, nu flux CLI — flux --no-headers nu există în v2.8.8)
kubectl get helmreleases -A --no-headers | grep " False "

# 3. Server resources
df / --output=pcent | tail -1
free -m | awk '/^Mem:/{printf "%.0f%%\n", $3/$2*100}'

# 4. Docker containers down
docker ps --filter "status=exited" --format "{{.Names}}"
```

## Regula de raportare

- **Totul OK** → scrie `HEARTBEAT_OK` în stdout, **NU trimite pe Telegram**
- **Warning** (disk >80%, pod restart loop) → trimite scurt pe Telegram în română
- **Critical** (nod down, serviciu principal down, disk >90%) → trimite imediat cu URGENT

## Cum trimiți pe Telegram (când e ceva de raportat)

```python
import json, urllib.request, urllib.parse

config  = json.load(open('/home/openclaw/.openclaw/openclaw.json'))
TOKEN   = config['channels']['telegram']['botToken']
CHAT_ID = config['channels']['telegram']['allowFrom'][0]

msg = "⚠️ *Infra Alert*\n\n" + descriere_problema  # max 300 chars, clar și direct

data = urllib.parse.urlencode({
    "chat_id":    CHAT_ID,
    "text":       msg,
    "parse_mode": "Markdown"
}).encode()

req = urllib.request.Request(
    f"https://api.telegram.org/bot{TOKEN}/sendMessage",
    data=data, method="POST"
)
with urllib.request.urlopen(req, timeout=10) as resp:
    result = json.load(resp)
    print(f"Telegram OK: message_id={result['result']['message_id']}")
```

## Format mesaj

```
🔴 *URGENT — Infra Alert*
Nod kubernetes-controlplane-2 NotReady de 15 minute.
Pods afectate: 34 în monitoring.
```

## Critical vs minor

**CRITICAL (trimite imediat):**
- K8s nod down sau NotReady
- Traefik / Authentik down
- Disk >90%
- Pods în CrashLoopBackOff în kube-system, flux-system, longhorn-system

**MINOR (trimite, nu URGENT):**
- Pod ne-critic în restart loop
- Disk 80-90%
- FluxCD reconciliation error pe app ne-critic

**SKIP (nu trimite nimic):**
- Totul OK → doar `HEARTBEAT_OK` în stdout
