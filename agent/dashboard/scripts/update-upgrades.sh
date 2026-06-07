#!/usr/bin/env bash
# Actualizează /srv/dashboard/data/upgrades.json cu PR-urile Renovate deschise
# Cron: */30 * * * * /srv/dashboard/update-upgrades.sh >> /home/openclaw/.openclaw/logs/update-upgrades.log 2>&1
# Sau manual înainte de sâmbătă pentru preview complet

set -euo pipefail

OUTPUT="/srv/dashboard/data/upgrades.json"
REPO="meroxdotdev/infrastructure"

python3 - <<'PYEOF'
import subprocess, json, re, os
from datetime import datetime, timezone

def run(cmd, timeout=20):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception as e:
        return ""

def gh_prs():
    out = run(f"gh pr list --repo {os.environ.get('REPO','meroxdotdev/infrastructure')} --state open --json number,title,url,createdAt,labels --limit 50")
    if not out:
        return []
    try:
        return json.loads(out)
    except:
        return []

def classify_pr(title):
    """Clasifică PR-ul după titlul semantic commit de la Renovate."""
    # feat(...)!: = BREAKING  |  feat: = minor  |  fix: = patch
    prefix = title.split(':')[0] if ':' in title else ''
    if '!' in prefix:
        return 'breaking'
    elif title.startswith('feat'):
        return 'minor'
    elif title.startswith('fix'):
        return 'patch'
    else:
        return 'info'

def extract_versions(title):
    m = re.search(r'\( (.+?) ➔ (.+?) \)', title)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return None, None

def extract_package(title):
    # "Update image ghcr.io/foo/bar/pkg-name ( v1 ➔ v2 )"
    m = re.search(r'[Uu]pdate (?:image |chart |tool )?(\S+)', title)
    if m:
        raw = m.group(1)
        # Simplifică la ultimul segment semnificativ
        parts = raw.split('/')
        # Ia ultimele 2 segmente dacă primul e ghcr.io/docker.io etc.
        if len(parts) > 2 and parts[0] in ('ghcr.io', 'docker.io', 'quay.io', 'registry.k8s.io'):
            return '/'.join(parts[-2:])
        return parts[-1]
    # Fallback: primele 40 caractere
    return title[:40]

prs = gh_prs()

items = []
for p in prs:
    title = p.get('title', '')
    kind = classify_pr(title)
    from_v, to_v = extract_versions(title)
    pkg = extract_package(title)
    labels = [l.get('name','') for l in p.get('labels', [])]
    items.append({
        "number": p['number'],
        "title": title,
        "url": p.get('url', ''),
        "package": pkg,
        "fromVersion": from_v,
        "toVersion": to_v,
        "kind": kind,          # breaking | minor | patch | info
        "labels": labels,
        "createdAt": p.get('createdAt', '')
    })

# Sortare: breaking > minor > patch
order = {"breaking": 0, "minor": 1, "patch": 2, "info": 3}
items.sort(key=lambda x: order.get(x['kind'], 9))

breaking = [i for i in items if i['kind'] == 'breaking']
minor    = [i for i in items if i['kind'] == 'minor']
patch    = [i for i in items if i['kind'] == 'patch']

result = {
    "timestamp": datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
    "repo": "meroxdotdev/infrastructure",
    "totalOpen": len(items),
    "breakingCount": len(breaking),
    "minorCount": len(minor),
    "patchCount": len(patch),
    "items": items,
    "summary": f"{len(breaking)} breaking, {len(minor)} minor, {len(patch)} patch"
}

out_path = "/srv/dashboard/data/upgrades.json"
with open(out_path, 'w') as f:
    json.dump(result, f, indent=2)

print(f"[{result['timestamp']}] upgrades.json actualizat: {result['summary']} ({len(items)} total)")
PYEOF
