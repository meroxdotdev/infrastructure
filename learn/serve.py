#!/usr/bin/env python3
"""Serve the learn/ web UI from the repository root, on localhost only.

Why the repo root and not learn/: the lessons link to the real files in this
repo (talos/talconfig.yaml, kubernetes/apps/...) and the UI opens them in a
viewer. Why a script and not `python -m http.server`: the repo root holds
age.key, kubeconfig and talosconfig, and a plain http.server would hand them
to anything that can reach the port. This one binds 127.0.0.1 and refuses
every path below that could hold a secret.

    python learn/serve.py            # http://127.0.0.1:8080/learn/
    python learn/serve.py --port 9000 --no-browser
"""
import argparse
import fnmatch
import functools
import http.server
import pathlib
import posixpath
import urllib.parse
import webbrowser

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Matched against the repo-relative path and against each of its parts.
DENY = [
    ".git", ".git/*",
    ".private", ".private/*",
    "*.key", "age.key",
    "kubeconfig", "*.kubeconfig", "talosconfig",
    "talos/clusterconfig/*",
    "*.tfvars", "*.tfstate", "*.tfstate.*", ".terraform", ".terraform/*",
    ".vault_pass", "*.vault_pass",
    ".env", "*.env.local",
    "github-push-token.txt", "cloudflare-tunnel.json",
    "SECURITY-AUDIT.md", "audit-log.md",
    "*.decrypted~*",
]


def denied(rel: str) -> bool:
    rel = rel.strip("/")
    if not rel:
        return False
    parts = rel.split("/")
    for pattern in DENY:
        if fnmatch.fnmatch(rel, pattern):
            return True
        if any(fnmatch.fnmatch(p, pattern) for p in parts):
            return True
    return False


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".md": "text/markdown; charset=utf-8",
        ".yaml": "text/plain; charset=utf-8",
        ".yml": "text/plain; charset=utf-8",
        ".json5": "text/plain; charset=utf-8",
        ".toml": "text/plain; charset=utf-8",
        ".tf": "text/plain; charset=utf-8",
        ".sh": "text/plain; charset=utf-8",
        ".j2": "text/plain; charset=utf-8",
        ".env": "text/plain; charset=utf-8",
        ".go": "text/plain; charset=utf-8",
        ".service": "text/plain; charset=utf-8",
        ".timer": "text/plain; charset=utf-8",
        ".conf": "text/plain; charset=utf-8",
    }

    def send_head(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        rel = posixpath.normpath(path).lstrip("/")
        if rel == ".":
            rel = ""
        if denied(rel):
            self.send_error(403, "Blocked by learn/serve.py: this path can hold a secret")
            return None
        return super().send_head()

    def end_headers(self):
        # Lessons are edited while the page is open; never serve a stale copy.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    handler = functools.partial(Handler, directory=str(ROOT))
    with http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler) as srv:
        url = f"http://127.0.0.1:{args.port}/learn/"
        print(f"learn: {url}  (root: {ROOT}, Ctrl+C to stop)")
        if not args.no_browser:
            webbrowser.open(url)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print()


if __name__ == "__main__":
    main()
