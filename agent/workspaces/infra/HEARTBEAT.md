# HEARTBEAT.md — Infra Agent

Runs twice daily (08:00 and 20:00 Romanian time).

## Checks to run

```bash
# 1. Cluster health
kubectl get nodes
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null

# 2. FluxCD drift
flux get all -A --status-selector=ready=false 2>/dev/null

# 3. Server resources
df -h | grep -E "^/dev" | awk '{if($5+0 > 80) print "DISK WARN: "$0}'
free -h

# 4. Docker containers down
docker ps --filter "status=exited" --format "{{.Names}}: {{.Status}}"
```

## Reporting rule

- **Everything OK** → `HEARTBEAT_OK` (do not send to Telegram)
- **Minor warning** (disk >80%, pod restart loop) → send short Telegram message in Romanian
- **Critical issue** (node down, main service down, security alert) → send immediately with URGENT

## Critical vs minor

**CRITICAL:**
- K8s node down or NotReady
- Traefik / Authentik down
- Disk >90%
- Core namespace pods in CrashLoopBackOff
- Suspicious activity in logs

**MINOR (report but not urgent):**
- Non-critical pod in restart loop
- Disk 80-90%
- FluxCD reconciliation error on non-critical app
