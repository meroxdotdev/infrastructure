#!/usr/bin/env python3
"""
Usage: python3 add-reminder.py "Text reminder" [--list "Cumpărături"] [--due "2026-06-04"]
Default list: Cumpărături
Default due: today
"""
import caldav, sys, uuid, argparse
from datetime import datetime, timezone, date
from icalendar import Calendar, Todo

env = {}
try:
    for line in open("/srv/dashboard/.env"):
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip()
except:
    pass

parser = argparse.ArgumentParser()
parser.add_argument("summary", help="Textul reminderului")
parser.add_argument("--list", default="Mementouri", help="Numele listei (Mementouri = singura lista CalDAV care sync cu Reminders iOS)")
parser.add_argument("--shopping", action="store_true", help="Adaugă prefix 🛒 (pentru cumpărături)")
parser.add_argument("--due", default=None, help="Data scadentă YYYY-MM-DD (implicit: azi)")
args = parser.parse_args()

due_date = date.fromisoformat(args.due) if args.due else date.today()
summary = ("🛒 " + args.summary) if args.shopping and not args.summary.startswith("🛒") else args.summary

client = caldav.DAVClient(url="https://caldav.icloud.com/", username=env["APPLE_ID"], password=env["APPLE_APP_PASSWORD"])
principal = client.principal()
calendars = principal.calendars()

# Try by display name first; fall back to cached URL (handles iCloud server redirects)
target = next((c for c in calendars if c.get_display_name() == args.list), None)
if not target:
    try:
        import json as _json
        urls = _json.load(open("/srv/dashboard/.caldav-urls.json"))
        if args.list in urls:
            target = client.calendar(url=urls[args.list])
    except Exception:
        pass
if not target:
    available = [c.get_display_name() for c in calendars]
    print(f"❌ Lista '{args.list}' nu există. Disponibile: {available}", file=sys.stderr)
    sys.exit(1)

cal = Calendar()
cal.add('prodid', '-//merox-dashboard//EN')
cal.add('version', '2.0')

todo = Todo()
todo.add('uid', str(uuid.uuid4()) + '@merox.dev')
todo.add('summary', summary)
todo.add('dtstart', due_date)
todo.add('due', due_date)
todo.add('dtstamp', datetime.now(timezone.utc))
todo.add('status', 'NEEDS-ACTION')

cal.add_component(todo)
target.add_todo(cal.to_ical())

print(f"✅ Adăugat în '{args.list}': {summary} (due: {due_date})")

# Refresh reminders.json immediately
import subprocess
subprocess.run(["bash", "/srv/dashboard/update-reminders.sh"], capture_output=True)
