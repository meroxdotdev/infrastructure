#!/bin/bash
# Verifică proposals.json și trimite Telegram dacă există propuneri noi (pending + nenotificate)

PROPOSALS="/srv/dashboard/data/proposals.json"
TG_SCRIPT="/srv/dashboard/tg-notify.sh"
NOTIFIED_FILE="/srv/dashboard/data/.proposals-notified.json"

[ -f "$PROPOSALS" ] || exit 0
[ -x "$TG_SCRIPT" ] || exit 0

python3 - << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone

proposals_path = '/srv/dashboard/data/proposals.json'
notified_path = '/srv/dashboard/data/.proposals-notified.json'
tg_script = '/srv/dashboard/tg-notify.sh'

with open(proposals_path) as f:
    data = json.load(f)

# Load already-notified IDs
notified = set()
if os.path.exists(notified_path):
    try:
        with open(notified_path) as f:
            notified = set(json.load(f))
    except:
        pass

pending = data.get('pending', [])
new_proposals = [p for p in pending if p.get('status') == 'pending' and p.get('id') not in notified]

if not new_proposals:
    print("No new proposals to notify")
    sys.exit(0)

# Build Telegram message
lines = ["🤖 *Orchestrator — propuneri noi*\n"]
for p in new_proposals:
    pid = p.get('id', '?')
    title = p.get('title', p.get('description', 'fără titlu'))[:100]
    impact = p.get('impact', '')
    lines.append(f"📋 *{title}*")
    if impact:
        lines.append(f"   Impact: {impact[:80]}")
    lines.append(f"   ✅ `/approve {pid}`  ❌ `/reject {pid}`\n")

msg = '\n'.join(lines)

# Send via tg-notify.sh
import subprocess
result = subprocess.run([tg_script, msg], capture_output=True, text=True)
if result.returncode == 0:
    # Mark as notified
    notified.update(p['id'] for p in new_proposals)
    with open(notified_path, 'w') as f:
        json.dump(list(notified), f)
    print(f"Notified {len(new_proposals)} proposals: {[p['id'] for p in new_proposals]}")
else:
    print(f"TG send failed: {result.stderr}")
    sys.exit(1)
PYEOF
