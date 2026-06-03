#!/bin/bash
# Syncs Apple Reminders (all lists) to /srv/dashboard/data/reminders.json
# Runs every 5 minutes via crontab — zero AI tokens

set -euo pipefail

python3 - <<'PYEOF'
import caldav, json, sys
from datetime import datetime, timezone, date as date_type
from icalendar import Calendar

env = {}
try:
    for line in open("/srv/dashboard/.env"):
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip()
except:
    pass

APPLE_ID = env.get("APPLE_ID", "")
APP_PASSWORD = env.get("APPLE_APP_PASSWORD", "")
OUTPUT = "/srv/dashboard/data/reminders.json"

client = caldav.DAVClient(url="https://caldav.icloud.com/", username=APPLE_ID, password=APP_PASSWORD)
principal = client.principal()
calendars = principal.calendars()

now = datetime.now(timezone.utc)
today_str = now.strftime('%Y-%m-%d')

lists = {}

for cal in calendars:
    cal_name = cal.get_display_name() or "Fără nume"
    try:
        todos = cal.search(todo=True)
        if not todos:
            continue
        items = []
        for t in todos:
            try:
                ical = Calendar.from_ical(t.data)
                for comp in ical.walk():
                    if comp.name != "VTODO":
                        continue
                    summary = str(comp.get("SUMMARY", "Fără titlu"))
                    status = str(comp.get("STATUS", "NEEDS-ACTION"))
                    if status == "COMPLETED":
                        continue  # skip completed
                    due = comp.get("DUE")
                    due_str = None
                    if due:
                        d = due.dt
                        if isinstance(d, datetime):
                            due_str = d.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
                        elif isinstance(d, date_type):
                            due_str = d.isoformat()
                    uid = str(comp.get("UID", ""))
                    items.append({
                        "uid": uid,
                        "summary": summary,
                        "due": due_str,
                        "status": status,
                    })
            except Exception as ex:
                continue
        if items:
            lists[cal_name] = items
    except Exception as e:
        continue

result = {
    "updatedAt": now.strftime('%Y-%m-%dT%H:%M:%SZ'),
    "lists": lists,
}

with open(OUTPUT, "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

total = sum(len(v) for v in lists.values())
print(f"[update-reminders] {total} remindere active în {len(lists)} liste")
for name, items in lists.items():
    print(f"  {name}: {len(items)} → {[i['summary'] for i in items]}")
PYEOF
