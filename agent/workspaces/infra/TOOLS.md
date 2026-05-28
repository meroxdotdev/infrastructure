# TOOLS.md — Infra Agent

## Useful commands

```bash
# Cluster
kubectl get nodes
kubectl get pods -A
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
flux get all -A --status-selector=ready=false
talosctl --talosconfig /home/openclaw/.talos/config health

# Server
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
df -h
free -h
ss -tlnp

# Logs
docker logs traefik --tail 50
journalctl -u ssh --since "1 hour ago" | grep -i "fail\|invalid\|error"
```

## Dashboard updates

Write infra status to `/srv/dashboard/data/infra.json` after each heartbeat:

```json
{
  "timestamp": "ISO_TIMESTAMP",
  "nodes": {"ready": "3/3", "status": "All healthy"},
  "pods": {"unhealthy": 0, "details": "All OK"},
  "disk": {"usage": "45%", "path": "/ on VPS"},
  "docker": {"running": 18, "stopped": 0},
  "flux": {"status": "OK", "details": "In sync"},
  "cert": {"days": "45d", "domain": "merox.dev"}
}
```

Update agent status in `/srv/dashboard/data/agents.json`:
```python
import json
from datetime import datetime
with open('/srv/dashboard/data/agents.json') as f: d = json.load(f)
d['infra'] = {'lastRun': datetime.utcnow().isoformat()+'Z', 'status': 'ok', 'summary': 'SUMMARY'}
with open('/srv/dashboard/data/agents.json', 'w') as f: json.dump(d, f, indent=2)
```

## Paths

- K8s config repo: `/srv/kubernetes/infrastructure/`
- GitHub: `meroxdotdev/infrastructure`
- Kubeconfig: `/home/openclaw/.kube/config`
- Talosconfig: `/home/openclaw/.talos/config`
- Docker services: `/srv/docker/`
