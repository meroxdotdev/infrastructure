#!/bin/bash
# Fetches iCloud Calendar events and writes /srv/dashboard/data/calendar.json
# Runs every 30 minutes via crontab — zero AI tokens

set -euo pipefail

python3 - <<'PYEOF'
import caldav, json, sys
from datetime import datetime, timezone, timedelta, date as date_type
from icalendar import Calendar as iCalendar

import os
env = {}
try:
    for line in open("/srv/dashboard/.env"):
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip()
except:
    pass

APPLE_ID = env.get("APPLE_ID") or os.environ.get("APPLE_ID", "")
APP_PASSWORD = env.get("APPLE_APP_PASSWORD") or os.environ.get("APPLE_APP_PASSWORD", "")
if not APPLE_ID or not APP_PASSWORD:
    print("[update-calendar] ERROR: credentials not found in /srv/dashboard/.env", file=sys.stderr)
    sys.exit(1)

CALDAV_URL = "https://caldav.icloud.com/"
OUTPUT = "/srv/dashboard/data/calendar.json"

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
    if "Mement" in cal_name or "Reminder" in cal_name:
        continue
    try:
        evs = cal.search(start=start, end=end, event=True, expand=True)
        for ev in evs:
            try:
                ical = iCalendar.from_ical(ev.data)
                for component in ical.walk():
                    if component.name != "VEVENT":
                        continue
                    summary = str(component.get("SUMMARY", "Fără titlu"))
                    location = str(component.get("LOCATION", "")) or None
                    dtstart = component.get("DTSTART").dt

                    if isinstance(dtstart, date_type) and not isinstance(dtstart, datetime):
                        # all-day event
                        dt_iso = dtstart.isoformat()
                        all_day = True
                        ts = datetime(dtstart.year, dtstart.month, dtstart.day, tzinfo=timezone.utc).timestamp()
                    else:
                        if isinstance(dtstart, datetime):
                            if dtstart.tzinfo is None:
                                dtstart = dtstart.replace(tzinfo=timezone.utc)
                        else:
                            dtstart = datetime(dtstart.year, dtstart.month, dtstart.day, tzinfo=timezone.utc)
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
            except Exception as ex:
                print(f"[update-calendar] parse error: {ex}", file=sys.stderr)
                continue
    except Exception as e:
        print(f"[update-calendar] Warning — {cal_name}: {e}", file=sys.stderr)

events_all.sort(key=lambda x: x["timestamp"])

# Inject recurring utility reminders — only on the first day of the window visible in range
RECURRING_REMINDERS = [
    {"day_range": (22, 26), "summary": "⚡ Transmite index electricitate (22-26)", "calendar": "Utilități"},
    {"day_range": (5, 10),  "summary": "🔥 Transmite index gaz (5-10)",            "calendar": "Utilități"},
]
check_start = start.date()
check_end = end.date()
for rem in RECURRING_REMINDERS:
    lo, hi = rem["day_range"]
    # find the first day in the fetch window that falls in [lo, hi]
    first_day = None
    cur = check_start
    while cur <= check_end:
        if lo <= cur.day <= hi:
            first_day = cur
            break
        cur += timedelta(days=1)
    if first_day:
        ts = datetime(first_day.year, first_day.month, first_day.day, tzinfo=timezone.utc).timestamp()
        events_all.append({
            "calendar": rem["calendar"],
            "summary": rem["summary"],
            "start": first_day.isoformat(),
            "timestamp": ts,
            "allDay": True,
            "location": None,
            "reminder": True,
        })

events_all.sort(key=lambda x: x["timestamp"])

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
    print(f"  {day_entry['date']}: {len(day_entry['events'])} ev — {[e['summary'] for e in day_entry['events']]}")
PYEOF
