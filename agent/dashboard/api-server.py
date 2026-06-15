#!/usr/bin/env python3
"""
Dashboard Agent API — serves log tails and creates run-trigger files.
Runs as a Docker container. Log dir and trigger dir are mounted volumes.
Host cron picks up trigger files and executes agents.
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

API_TOKEN = os.environ.get("DASHBOARD_API_TOKEN", "")
LOG_DIR = "/logs"
TRIGGER_DIR = "/triggers"

AGENTS = [
    "news", "infra", "costs", "dashboard",
    "orchestrator", "blog", "renovate", "repo", "design", "site",
]

LOG_FILES = {
    "news":         "heartbeat-news.log",
    "infra":        "heartbeat-infra.log",
    "costs":        "heartbeat-costs.log",
    "dashboard":    "heartbeat-dashboard.log",
    "orchestrator": "heartbeat-orchestrator.log",
    "blog":         "heartbeat-blog.log",
    "renovate":     "heartbeat-renovate.log",
    "repo":         "heartbeat-repo.log",
    "design":       "heartbeat-design.log",
    "site":         "heartbeat-site.log",
}


def tail_log(agent, lines=25):
    log_file = LOG_FILES.get(agent)
    if not log_file:
        return None
    path = os.path.join(LOG_DIR, log_file)
    if not os.path.exists(path):
        return f"[no log yet at {path}]"
    try:
        with open(path, "r", errors="replace") as f:
            all_lines = f.readlines()
        return "".join(all_lines[-lines:]) or "[empty log]"
    except Exception as e:
        return f"[error reading log: {e}]"


def create_trigger(agent):
    trigger_path = os.path.join(TRIGGER_DIR, f"{agent}.trigger")
    if os.path.exists(trigger_path):
        return False, "trigger already pending"
    try:
        with open(trigger_path, "w") as f:
            f.write(str(time.time()))
        return True, "trigger created"
    except Exception as e:
        return False, str(e)


def is_running(agent):
    return os.path.exists(os.path.join(TRIGGER_DIR, f"{agent}.trigger"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def check_token(self):
        if not API_TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {API_TOKEN}"

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path == "/api/health":
            self.send_json(200, {"ok": True})
            return

        if not self.check_token():
            self.send_json(401, {"error": "unauthorized"})
            return

        if parsed.path == "/api/logs":
            agent = qs.get("agent", [None])[0]
            lines = int(qs.get("lines", [25])[0])
            lines = min(lines, 100)
            if agent not in AGENTS:
                self.send_json(400, {"error": "unknown agent"})
                return
            log = tail_log(agent, lines)
            self.send_json(200, {
                "agent": agent,
                "log": log,
                "pending": is_running(agent),
            })
            return

        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if not self.check_token():
            self.send_json(401, {"error": "unauthorized"})
            return

        if parsed.path == "/api/run":
            agent = qs.get("agent", [None])[0]
            if agent not in AGENTS:
                self.send_json(400, {"error": "unknown agent"})
                return
            ok, msg = create_trigger(agent)
            self.send_json(200, {"agent": agent, "ok": ok, "message": msg})
            return

        self.send_json(404, {"error": "not found"})


if __name__ == "__main__":
    port = int(os.environ.get("API_PORT", "8765"))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"[api-server] listening on 0.0.0.0:{port}", flush=True)
    server.serve_forever()
