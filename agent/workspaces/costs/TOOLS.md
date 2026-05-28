# TOOLS.md — Costs & Backup Agent

## Backup verification commands

```bash
# Longhorn backups
kubectl get backups -n longhorn-system -A
kubectl get snapshots -n longhorn-system -A

# Garage S3 storage
docker exec garage /garage/garage status
docker exec garage /garage/garage stats

# Docker volumes
docker volume ls
docker system df -v

# Space usage
df -h
du -sh /srv/* 2>/dev/null | sort -rh
```

## Dashboard updates

Write backup status to `/srv/dashboard/data/backup.json` after each check:
```json
{
  "timestamp": "ISO_TIMESTAMP",
  "services": [
    {"name": "Longhorn PVCs", "status": "ok", "lastBackup": "yesterday"},
    {"name": "Joplin DB", "status": "warn", "lastBackup": "5 days ago"},
    {"name": "Garage S3", "status": "ok", "lastBackup": "running"},
    {"name": "Portainer config", "status": "unknown", "lastBackup": null}
  ]
}
```

Update agent status in `/srv/dashboard/data/agents.json`:
```python
import json
from datetime import datetime
with open('/srv/dashboard/data/agents.json') as f: d = json.load(f)
d['costs'] = {'lastRun': datetime.utcnow().isoformat()+'Z', 'status': 'ok', 'summary': 'SUMMARY'}
with open('/srv/dashboard/data/agents.json', 'w') as f: json.dump(d, f, indent=2)
```

## Memory files

- `memory/monthly-YYYY-MM.md` — monthly resource snapshot (disk, docker images, backup status)
- `memory/backup-state.json` — last verification date per service
