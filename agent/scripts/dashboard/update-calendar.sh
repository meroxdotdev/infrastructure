#!/bin/bash
# Fetches iCloud Calendar events and writes /srv/dashboard/data/calendar.json
# Runs every 30 minutes via crontab — zero AI tokens

set -euo pipefail

python3 - <<'PYEOF'
import caldav, json, sys
from datetime import datetime, timezone, timedelta

import os, subprocess
env = {}
try:
    for line in open("/srv/dashboard/.env"):
        line=line.strip()
        if '=' in line and not line.startswith('#'):
            k,v=line.split('=',1)
            env[k.strip()]=v.strip()
except: pass
APPLE_ID = env.get("APPLE_ID") or os.environ.get("APPLE_ID","")
APP_PASSWORD = env.get("APPLE_APP_PASSWORD") or os.environ.get("APPLE_APP_PASSWORD","")
if not APPLE_ID or not APP_PASSWORD:
    print("[update-calendar] ERROR: credentials not found in /srv/dashboard/.env", file=sys.stderr)
    sys.exit(1)
CALDAV_URL = "https://caldav.icloud.com/"
OUTPUT = "/srv/dashboard/data/calendar.json"

# Fetch events: today + next 7 days
now = datetime.now(timezone.utc)
start = now.replace(hour=0, minute=0, second=0, microsecond=0)
end = start + timedelta(days=7)

try:
    client = caldav.DAVClient(url=CALDAV_URL, username=APPLE_ID, password=APP_PASSWORD)
    principal = client.principal()
    calendars = principal.calendars()
except Exception as e:
    print(f"[update-calendar] ERROR connecting: {e}", file=sys.stderr)
    sys.exit(1)

events_all = []
for cal in calendars:
    cal_name = cal.get_display_name() or "Calendar"
    # Skip Reminders (Mementouri)
    if "Mement" in cal_name or "Reminder" in cal_name:
        continue
    try:
        evs = cal.search(start=start, end=end, event=True, expand=True)
        for ev in evs:
            try:
                vev = ev.instance.vevent
                dtstart = vev.dtstart.value
                dtend = getattr(vev, 'dtend', None)
                summary = str(getattr(vev, 'summary', '').value) if hasattr(vev, 'summary') else 'Fără titlu'
                location = str(getattr(vev, 'location', '').value) if hasattr(vev, 'location') else None

                # Normalize to datetime
                if hasattr(dtstart, 'date') and not isinstance(dtstart, datetime):
                    # all-day event
                    dt_iso = dtstart.isoformat()
                    all_day = True
                    ts = datetime(dtstart.year, dtstart.month, dtstart.day, tzinfo=timezone.utc).timestamp()
                else:
                    if dtstart.tzinfo is None:
                        dtstart = dtstart.replace(tzinfo=timezone.utc)
                    dt_iso = dtstart.isoformat()
                    all_day = False
                    ts = dtstart.timestamp()

                events_all.append({
                    "calendar": cal_name,
                    "summary": summary,
                    "start": dt_iso,
                    "timestamp": ts,
                    "allDay": all_day,
                    "location": location,
                })
            except Exception:
                continue
    except Exception as e:
        print(f"[update-calendar] Warning — {cal_name}: {e}", file=sys.stderr)

events_all.sort(key=lambda x: x["timestamp"])

# Group by day
from collections import defaultdict
by_day = defaultdict(list)
for ev in events_all:
    if ev["allDay"]:
        day = ev["start"][:10]
    else:
        try:
            day = datetime.fromisoformat(ev["start"]).astimezone(timezone.utc).strftime('%Y-%m-%d')
        except:
            day = ev["start"][:10]
    by_day[day].append(ev)

result = {
    "updatedAt": now.strftime('%Y-%m-%dT%H:%M:%SZ'),
    "fetchedFrom": start.strftime('%Y-%m-%d'),
    "fetchedTo": end.strftime('%Y-%m-%d'),
    "totalEvents": len(events_all),
    "days": [
        {"date": d, "events": evs}
        for d, evs in sorted(by_day.items())
    ]
}

with open(OUTPUT, "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print(f"[update-calendar] {len(events_all)} evenimente în următoarele 7 zile")
for day_entry in result["days"]:
    print(f"  {day_entry['date']}: {len(day_entry['events'])} ev")
PYEOF
