#!/usr/bin/env bash
# Updates /srv/dashboard/data/news-releases.json via GitHub Releases API — zero AI tokens
# Output: pre-fetch only — news.json is owned by the news agent
# Cron: 0 */6 * * * /srv/dashboard/update-news.sh >> /home/openclaw/.openclaw/logs/update-news.log 2>&1

set -euo pipefail

python3 - <<'PYEOF'
import subprocess, json, os, stat, re, urllib.request, urllib.error
from datetime import datetime, timezone, timedelta

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except Exception:
        return ""

def gh_releases(owner, repo, per_page=5):
    url = f"https://api.github.com/repos/{owner}/{repo}/releases?per_page={per_page}"
    req = urllib.request.Request(url, headers={"User-Agent": "merox-dashboard/1.0", "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print(f"  [rate-limit] {owner}/{repo}: {e}")
        else:
            print(f"  [http-error] {owner}/{repo}: {e}")
        return []
    except Exception as e:
        print(f"  [error] {owner}/{repo}: {e}")
        return []

def parse_version(tag):
    tag = tag.lstrip("v")
    parts = re.findall(r'\d+', tag)
    return tuple(int(p) for p in parts[:3]) if parts else (0,)

def version_behind(running_tag, latest_tag):
    r = parse_version(running_tag)
    l = parse_version(latest_tag)
    if l > r:
        r_major, l_major = r[0] if r else 0, l[0] if l else 0
        r_minor, l_minor = r[1] if len(r) > 1 else 0, l[1] if len(l) > 1 else 0
        if l_major > r_major: return "major"
        if l_minor > r_minor: return "minor"
        return "patch"
    return None

def has_cve(text):
    return bool(re.search(r'CVE-\d{4}-\d+', text or "", re.IGNORECASE))

RO_MONTHS = ["Ian", "Feb", "Mar", "Apr", "Mai", "Iun", "Iul", "Aug", "Sep", "Oct", "Nov", "Dec"]
def fmt_date(iso):
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return f"{dt.day} {RO_MONTHS[dt.month - 1]}"
    except Exception:
        return iso[:10] if iso else "?"

now_utc = datetime.now(timezone.utc)
cutoff  = now_utc - timedelta(days=45)

# ── Detect running versions ──
running = {}
running["longhorn"]  = run("kubectl get helmrelease longhorn -n longhorn-system -o jsonpath='{.status.history[0].chartVersion}' 2>/dev/null") or "1.11.2"
running["talos"]     = re.search(r'v[\d.]+', run("kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null") or "").group() if re.search(r'v[\d.]+', run("kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null") or "") else "v1.13.0"
running["k8s"]       = run("kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null") or "v1.36.0"
running["flux-op"]   = run("kubectl get helmrelease flux-operator -n flux-system -o jsonpath='{.status.history[0].chartVersion}' 2>/dev/null") or "0.50.0"
# Authentik: find image from any pod in namespace (outpost shares version tag)
auth_img = run("kubectl get pods -A -o custom-columns=IMAGE:.spec.containers[0].image --no-headers 2>/dev/null | grep goauthentik | head -1")
auth_match = re.search(r':(\d{4}\.\d+\.?\d*)', auth_img or "")
running["authentik"] = auth_match.group(1) if auth_match else ""

print(f"Running versions: {running}")

# ── Projects to track ──
PROJECTS = [
    {"key": "authentik",  "owner": "goauthentik",  "repo": "authentik",    "running_key": "authentik"},
    {"key": "longhorn",   "owner": "longhorn",      "repo": "longhorn",     "running_key": "longhorn"},
    {"key": "flux2",      "owner": "fluxcd",        "repo": "flux2",        "running_key": None},
    {"key": "flux-op",    "owner": "controlplaneio-fluxcd", "repo": "flux-operator", "running_key": "flux-op"},
    {"key": "talos",      "owner": "siderolabs",    "repo": "talos",        "running_key": "talos"},
    {"key": "k8s",        "owner": "kubernetes",    "repo": "kubernetes",   "running_key": "k8s"},
]

items = []
seen_tags = set()

for proj in PROJECTS:
    releases = gh_releases(proj["owner"], proj["repo"])
    if not releases:
        continue
    latest = releases[0]
    latest_tag = latest.get("tag_name", "")

    for rel in releases:
        tag       = rel.get("tag_name", "")
        published = rel.get("published_at", "")
        title     = rel.get("name") or tag
        body      = rel.get("body", "") or ""
        url       = rel.get("html_url", "")
        prerel    = rel.get("prerelease", False)

        if prerel:
            continue
        # Skip releases older than cutoff
        try:
            rel_dt = datetime.fromisoformat(published.replace("Z", "+00:00"))
            if rel_dt < cutoff:
                continue
        except Exception:
            pass

        dedup_key = f"{proj['key']}:{tag}"
        if dedup_key in seen_tags:
            continue
        seen_tags.add(dedup_key)

        run_tag = running.get(proj["running_key"] or "", "") if proj["running_key"] else ""
        behind  = version_behind(run_tag, tag) if run_tag else None

        # Skip releases older than what we're already running (not actionable)
        if run_tag and behind is None and tag != latest_tag:
            continue

        cve_found = has_cve(title) or has_cve(body[:500])

        # Priority: only escalate to critical/warn if we actually need to act (behind or unknown)
        if cve_found and behind:
            priority = "critical"
        elif cve_found and not run_tag:
            priority = "warn"
        elif behind in ("major", "minor", "patch"):
            priority = "warn"
        elif cve_found and behind is None:
            # CVE in latest — we're already on it, just inform
            priority = "info"
        else:
            priority = "info"

        # Build title
        run_info = ""
        if run_tag and behind:
            run_info = f" — rulezi {run_tag}, upgrade disponibil"
        elif run_tag and not behind:
            run_info = f" — rulezi {run_tag} ✓"

        clean_tag = re.sub(r'^version/', '', tag)
        base_title = f"{proj['key'].capitalize()} {clean_tag}"
        if title and title != tag and title != clean_tag:
            base_title = f"{proj['key'].capitalize()} {clean_tag} — {title}"
        item_title = f"{base_title}{run_info}"
        if len(item_title) > 120:
            item_title = item_title[:117] + "..."

        items.append({
            "title":    item_title,
            "url":      url,
            "source":   "GitHub",
            "date":     fmt_date(published),
            "priority": priority,
            "_ts":      published
        })

# ── Hacker News top stories — strict AGENTS.md filter ──
# Include ONLY: AI/LLM releases, security CVEs, DevOps/infra major changes,
# self-hosting tools with real traction, privacy policy changes, science/space,
# big tech product launches, major global events.

HN_KEYWORDS_REQUIRED = [
    r'\b(llm|gpt|claude|gemini|mistral|openai|anthropic|model release|open.?source model)\b',
    r'\b(cve|vulnerability|exploit|breach|ransomware|zero.?day|patch|security fix)\b',
    r'\b(kubernetes|k8s|gitops|flux|argocd|docker|helm|terraform|cilium|talos|longhorn)\b',
    r'\b(self.host|homelab|selfhost)\b',
    r'\b(privacy|surveillance|gdpr|wiretap|tls intercept)\b',
    r'\b(nasa|esa|spacex|launch|orbit|rocket|telescope|discovery|breakthrough)\b',
    r'\b(acquisition|acquires|raises \$|series [a-e]|ipo|major release|shutdown|ban)\b',
    r'\b(bitcoin|solana|ethereum|halving|mainnet|protocol upgrade)\b',
]

HN_KEYWORDS_SKIP = [
    r'\bwhy i \b|\bhow i \b|\bmy experience\b|\bi switched\b',
    r'\bcareer\b|\binterview\b|\bjob\b|\bresume\b|\bsalary\b',
    r'^(ask hn:|show hn: my )',
    r'\b(font|typeface|essay|poem|novel|recipe|coffee|cheese)\b',
]

def hn_relevant(title):
    t = title.lower()
    if any(re.search(p, t, re.IGNORECASE) for p in HN_KEYWORDS_SKIP):
        return False
    return any(re.search(p, t, re.IGNORECASE) for p in HN_KEYWORDS_REQUIRED)

def hn_title_tokens(t):
    stop = {'the','a','an','is','in','of','to','and','or','for','on','at','by','with',
            'from','this','that','its','was','are','has','have','been','how','why','when'}
    return set(w.lower() for w in re.findall(r'[a-z]{4,}', t.lower()) if w not in stop)

hn_seen_tokens = []

try:
    req = urllib.request.Request(
        "https://hacker-news.firebaseio.com/v0/topstories.json",
        headers={"User-Agent": "merox-dashboard/1.0"}
    )
    with urllib.request.urlopen(req, timeout=8) as resp:
        hn_ids = json.load(resp)[:50]

    for hn_id in hn_ids:
        if len([i for i in items if i.get("source") == "Hacker News"]) >= 5:
            break
        try:
            req2 = urllib.request.Request(
                f"https://hacker-news.firebaseio.com/v0/item/{hn_id}.json",
                headers={"User-Agent": "merox-dashboard/1.0"}
            )
            with urllib.request.urlopen(req2, timeout=5) as resp2:
                story = json.load(resp2)
            if not story or story.get("type") != "story":
                continue
            title     = story.get("title", "")
            url       = story.get("url") or f"https://news.ycombinator.com/item?id={hn_id}"
            score     = story.get("score", 0)
            time_unix = story.get("time", 0)

            if score < 200:
                continue
            if not hn_relevant(title):
                print(f"  [hn-skip] score={score} title={title!r}")
                continue

            story_dt = datetime.fromtimestamp(time_unix, tz=timezone.utc) if time_unix else now_utc
            if story_dt < cutoff:
                continue

            tokens = hn_title_tokens(title)
            if any(len(tokens & prev) >= 3 for prev in hn_seen_tokens):
                continue
            hn_seen_tokens.append(tokens)

            items.append({
                "title":    title,
                "url":      url,
                "source":   "Hacker News",
                "date":     fmt_date(story_dt.strftime("%Y-%m-%dT%H:%M:%SZ")),
                "priority": "info",
                "_ts":      story_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
            })
        except Exception:
            continue
except Exception as e:
    print(f"  [hn-error] {e}")

# Sort: newest first, then stable-sort by priority (critical→warn→info)
PRIO = {"critical": 0, "warn": 1, "info": 2}
items.sort(key=lambda x: x.get("_ts", ""), reverse=True)   # newest first
items.sort(key=lambda x: PRIO.get(x["priority"], 2))        # priority buckets (stable)

# Strip internal sort field before saving
for item in items:
    item.pop("_ts", None)

today_ro = f"{now_utc.day} {RO_MONTHS[now_utc.month - 1]} {now_utc.year}"

data = {
    "date":  today_ro,
    "items": items
}

out = "/srv/dashboard/data/news-releases.json"
with open(out, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.chmod(out, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)

crit = sum(1 for i in items if i["priority"] == "critical")
warn = sum(1 for i in items if i["priority"] == "warn")
print(f"[{now_utc.strftime('%Y-%m-%dT%H:%M:%SZ')}] news-releases.json: {len(items)} items (critical={crit} warn={warn})")
PYEOF
