#!/usr/bin/env bash
# Sanitize agents.json: fix malformed ISO timestamps like "+00:00Z" -> "Z"
python3 - <<'PYEOF'
import json, re

path = '/srv/dashboard/data/agents.json'
with open(path) as f:
    d = json.load(f)

fixed = 0
for key, val in d.items():
    ts = val.get('lastRun', '')
    if ts and re.search(r'\+00:00Z$', ts):
        d[key]['lastRun'] = ts[:-len('+00:00Z')] + 'Z'
        print(f"  fixed {key}: {ts!r} -> {d[key]['lastRun']!r}")
        fixed += 1

if fixed:
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
    print(f"Saved {fixed} fix(es) to agents.json")
else:
    print("No malformed timestamps found.")
PYEOF
