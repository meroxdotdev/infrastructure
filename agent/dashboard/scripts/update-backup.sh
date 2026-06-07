#!/usr/bin/env bash
# Updates /srv/dashboard/data/backup.json — zero AI tokens
# Reads Garage credentials from /srv/dashboard/.env

set -euo pipefail

ENV_FILE="/srv/dashboard/.env"
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

GARAGE_TOKEN="${GARAGE_TOKEN:-}"
GARAGE_BUCKET_ID="${GARAGE_BUCKET_ID:-}"

if [[ -z "$GARAGE_TOKEN" || -z "$GARAGE_BUCKET_ID" ]]; then
    echo "ERROR: GARAGE_TOKEN or GARAGE_BUCKET_ID not set in $ENV_FILE" >&2
    exit 1
fi

python3 - "$GARAGE_TOKEN" "$GARAGE_BUCKET_ID" <<'PYEOF'
import subprocess, json, os, stat, sys, re, urllib.request
from datetime import datetime, timezone

GARAGE_TOKEN     = sys.argv[1]
GARAGE_BUCKET_ID = sys.argv[2]

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        return r.stdout.strip()
    except Exception:
        return ""

def garage_api(path):
    req = urllib.request.Request(
        f"http://localhost:3903{path}",
        headers={"Authorization": f"Bearer {GARAGE_TOKEN}"}
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.load(resp)

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# ── NAS ──
nas_raw   = run("df -B1 /mnt/nas 2>/dev/null | tail -1")
nas_parts = nas_raw.split()
if len(nas_parts) >= 5:
    nas_total = int(nas_parts[1])
    nas_avail = int(nas_parts[3])
    nas_pct   = int(nas_parts[4].rstrip('%'))
    def fmt(b):
        if b >= 1024**4: return f"{b/1024**4:.1f}T"
        if b >= 1024**3: return f"{b/1024**3:.1f}G"
        return f"{b//1024**2}M"
    nas_desc   = f"{fmt(nas_total)} total, {fmt(nas_avail)} disponibil ({nas_pct}% folosit)"
    nas_status = "ok"
else:
    nas_desc   = "NAS indisponibil"
    nas_status = "unknown"

# ── Longhorn latest backup ──
lh_raw   = run("kubectl get backups.longhorn.io -A --no-headers 2>/dev/null")
lh_lines = [l for l in lh_raw.splitlines() if "Completed" in l]
if lh_lines:
    def lh_sort_key(line):
        parts = line.split()
        return parts[-1] if parts else ""
    lh_lines.sort(key=lh_sort_key)
    parts     = lh_lines[-1].split()
    lh_time   = parts[-1]
    lh_desc   = f"azi ({lh_time})" if lh_time.startswith(now[:10]) else lh_time
    lh_status = "ok"
else:
    lh_desc   = "Nu s-au găsit backup-uri finalizate"
    lh_status = "unknown"

# ── Garage S3 ──
try:
    bucket = garage_api(f"/v2/GetBucketInfo?id={GARAGE_BUCKET_ID}")
    stats  = garage_api("/v2/GetClusterStatistics")
    objects   = bucket.get("objects", 0)
    m = re.search(r"(\d+\.?\d*)\s*GB\s*/\s*(\d+\.?\d*)\s*GB", stats.get("freeform", ""))
    if m:
        avail_gb = float(m.group(1))
        garage_desc = f"running - {avail_gb:.1f} GB disponibil, {objects:,} obiecte, fără erori"
    else:
        used_gb = bucket.get("bytes", 0) / 1024**3
        garage_desc = f"running - {objects:,} obiecte, {used_gb:.1f}GB folosit"
    garage_status = "ok"
except Exception as e:
    garage_desc   = f"API error: {e}"
    garage_status = "unknown"

data = {
    "timestamp": now,
    "services": [
        {"name": "Longhorn PVCs",     "status": lh_status,     "lastBackup": lh_desc},
        {"name": "Garage S3",         "status": garage_status,  "lastBackup": garage_desc},
        {"name": "NAS Mount",         "status": nas_status,     "lastBackup": nas_desc},
        {"name": "Portainer config",  "status": "unknown",      "lastBackup": None}
    ]
}

out = "/srv/dashboard/data/backup.json"
with open(out, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(out, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)

print(f"[{now}] backup.json: garage={garage_status} nas={nas_status} lh={lh_status} | {garage_desc[:60]}")
PYEOF
