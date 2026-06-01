#!/usr/bin/env bash
# Updates /srv/dashboard/data/infra.json — zero AI tokens
# Cron: */5 * * * * /srv/dashboard/update-infra.sh >> /home/openclaw/.openclaw/logs/update-infra.log 2>&1

set -euo pipefail

python3 - <<'PYEOF'
import subprocess, json, os, stat
from datetime import datetime, timezone

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        return r.stdout.strip()
    except Exception:
        return ""

# Nodes
nodes_raw = run("kubectl get nodes --no-headers 2>/dev/null")
nodes_lines = [l for l in nodes_raw.splitlines() if l.strip()]
nodes_ready = sum(1 for l in nodes_lines if " Ready " in l)
nodes_total = len(nodes_lines)

# Node CPU/MEM metrics
metrics = []
top_raw = run("kubectl top nodes --no-headers 2>/dev/null")
for line in top_raw.splitlines():
    p = line.split()
    if len(p) >= 5:
        try:
            metrics.append({"name": p[0], "cpu": int(p[2].rstrip('%')), "mem": int(p[4].rstrip('%'))})
        except (ValueError, IndexError):
            pass

# Unhealthy pods
pods_raw = run("kubectl get pods -A --no-headers 2>/dev/null")
pods_lines = [l for l in pods_raw.splitlines() if l.strip()]
total_pods = len(pods_lines)
unhealthy = sum(1 for l in pods_lines if not any(s in l for s in [" Running ", " Completed ", " Succeeded "]))

# Namespaces with pod counts (reuse pods_raw)
ns_pods = {}
for line in pods_lines:
    parts = line.split()
    if parts:
        ns = parts[0]
        ns_pods[ns] = ns_pods.get(ns, 0) + 1

# Disk VPS
disk_raw = run("df / --output=pcent,used,size,avail 2>/dev/null | tail -1")
disk_parts = disk_raw.split()
disk_pct  = int(disk_parts[0].rstrip('%')) if disk_parts else 0
disk_used  = disk_parts[1] if len(disk_parts) > 1 else "?"
disk_total = disk_parts[2] if len(disk_parts) > 2 else "?"
disk_free  = disk_parts[3] if len(disk_parts) > 3 else "?"

# Memory VPS
mem_raw = run("free -m 2>/dev/null | awk '/^Mem:/{print $2,$3}'")
mem_parts = mem_raw.split()
mem_total = int(mem_parts[0]) if mem_parts else 0
mem_used  = int(mem_parts[1]) if len(mem_parts) > 1 else 0
mem_pct   = (mem_used * 100 // mem_total) if mem_total > 0 else 0

# Docker
docker_names_raw = run("docker ps --format '{{.Names}}' 2>/dev/null")
docker_names = [n for n in docker_names_raw.splitlines() if n.strip()]
docker_running = len(docker_names)
docker_stopped = int(run("docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | wc -l") or 0)

# Flux HelmReleases
flux_raw = run("kubectl get helmreleases -A --no-headers 2>/dev/null")
flux_ok   = sum(1 for l in flux_raw.splitlines() if " True " in l)
flux_fail = sum(1 for l in flux_raw.splitlines() if " False " in l)

# Longhorn volumes
lh_raw   = run("kubectl get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null")
lh_lines  = [l for l in lh_raw.splitlines() if l.strip()]
lh_total   = len(lh_lines)
lh_healthy = sum(1 for l in lh_lines if "healthy" in l)

# Longhorn per-node storage (bytes) from nodes.longhorn.io
lh_nodes = []
lh_nodes_raw = run("kubectl get nodes.longhorn.io -n longhorn-system -o json 2>/dev/null")
if lh_nodes_raw:
    try:
        lh_node_data = json.loads(lh_nodes_raw)
        for item in lh_node_data.get("items", []):
            name = item["metadata"]["name"]
            for disk_status in item.get("status", {}).get("diskStatus", {}).values():
                avail = disk_status.get("storageAvailable", 0)
                total = disk_status.get("storageMaximum", 0)
                if total > 0:
                    lh_nodes.append({"name": name, "used": total - avail, "total": total})
                    break  # one disk entry per node
    except (json.JSONDecodeError, KeyError):
        pass

lh_used_g  = round(sum(n["used"]  for n in lh_nodes) / 1024**3) if lh_nodes else None
lh_total_g = round(sum(n["total"] for n in lh_nodes) / 1024**3) if lh_nodes else None

data = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "nodes": {
        "ready": f"{nodes_ready}/{nodes_total}",
        "status": "All healthy" if nodes_ready == nodes_total else "Degraded",
        "metrics": metrics
    },
    "pods": {
        "unhealthy": unhealthy,
        "total": total_pods,
        "details": "All OK" if unhealthy == 0 else f"{unhealthy} unhealthy"
    },
    "disk": {
        "usage": f"{disk_pct}%",
        "pct": disk_pct,
        "used": disk_used,
        "total": disk_total,
        "free": disk_free
    },
    "memory": {
        "usedMB": mem_used,
        "totalMB": mem_total,
        "pct": mem_pct
    },
    "docker": {
        "running": docker_running,
        "stopped": docker_stopped,
        "names": docker_names
    },
    "flux": {
        "ok": flux_ok,
        "failed": flux_fail,
        "status": "All synced" if flux_fail == 0 else f"{flux_fail} failed"
    },
    "longhorn": {
        "total": lh_total,
        "healthy": lh_healthy,
        "usedG": lh_used_g,
        "totalG": f"{lh_total_g}G" if lh_total_g else None
    },
    "longhornNodes": lh_nodes,
    "namespaces": ns_pods
}

out = "/srv/dashboard/data/infra.json"
with open(out, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(out, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)

print(f"[{data['timestamp']}] nodes={data['nodes']['ready']} pods_unhealthy={unhealthy} "
      f"disk={disk_pct}% mem={mem_pct}% docker={docker_running} flux_ok={flux_ok} "
      f"lh={lh_healthy}/{lh_total} lh_nodes={len(lh_nodes)}")
PYEOF
