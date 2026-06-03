#!/usr/bin/env python3
"""
Manage todos.json
Usage:
  python3 todo.py add "Text" [--list "Cumpărături"]
  python3 todo.py done "Text" [--list "Cumpărături"]
  python3 todo.py remove "Text" [--list "Cumpărături"]
  python3 todo.py list
  python3 todo.py clear --list "Cumpărături"
"""
import json, sys, argparse, uuid
from datetime import datetime, timezone

TODOS_PATH = "/srv/dashboard/data/todos.json"

def load():
    try:
        with open(TODOS_PATH) as f:
            return json.load(f)
    except:
        return {"lists": {}}

def save(data):
    data["updatedAt"] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    with open(TODOS_PATH, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

parser = argparse.ArgumentParser()
sub = parser.add_subparsers(dest="cmd")

p_add = sub.add_parser("add")
p_add.add_argument("text")
p_add.add_argument("--list", default="Cumpărături")

p_done = sub.add_parser("done")
p_done.add_argument("text")
p_done.add_argument("--list", default="Cumpărături")

p_remove = sub.add_parser("remove")
p_remove.add_argument("text")
p_remove.add_argument("--list", default="Cumpărături")

p_list = sub.add_parser("list")

p_clear = sub.add_parser("clear")
p_clear.add_argument("--list", default="Cumpărături")

args = parser.parse_args()
data = load()

today = datetime.now(timezone.utc).strftime('%Y-%m-%d')

if args.cmd == "add":
    lst = data["lists"].setdefault(args.list, [])
    # avoid duplicates
    if any(i["text"].lower() == args.text.lower() and not i["done"] for i in lst):
        print(f"⚠️  '{args.text}' există deja în {args.list}")
        sys.exit(0)
    lst.append({"id": str(uuid.uuid4())[:8], "text": args.text, "done": False, "addedAt": today})
    save(data)
    print(f"✅ Adăugat în {args.list}: {args.text}")

elif args.cmd == "done":
    lst = data["lists"].get(args.list, [])
    matched = [i for i in lst if args.text.lower() in i["text"].lower() and not i["done"]]
    if not matched:
        print(f"❌ Nu am găsit '{args.text}' în {args.list}")
        sys.exit(1)
    for i in matched:
        i["done"] = True
        i["doneAt"] = today
    save(data)
    print(f"✅ Bifat: {[i['text'] for i in matched]}")

elif args.cmd == "remove":
    lst = data["lists"].get(args.list, [])
    before = len(lst)
    data["lists"][args.list] = [i for i in lst if args.text.lower() not in i["text"].lower()]
    save(data)
    removed = before - len(data["lists"][args.list])
    print(f"🗑️  Șters {removed} item(e) din {args.list}")

elif args.cmd == "clear":
    data["lists"][args.list] = []
    save(data)
    print(f"🗑️  {args.list} golit")

elif args.cmd == "list":
    for lst_name, items in data["lists"].items():
        active = [i for i in items if not i["done"]]
        print(f"\n📋 {lst_name} ({len(active)} active):")
        for i in active:
            print(f"  ○ {i['text']}  [{i['addedAt']}]")
else:
    parser.print_help()
