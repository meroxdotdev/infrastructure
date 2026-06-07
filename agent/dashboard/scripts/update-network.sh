#!/bin/bash
# Scans homelab subnets and writes /srv/dashboard/data/network.json — zero AI tokens
# Runs every hour via crontab

set -euo pipefail

python3 - <<'PYEOF'
import json, sys, subprocess, socket, datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

SUBNETS = [
    {"name": "Homelab LAN",  "cidr": "10.57.57.0/24"},
    {"name": "WiFi",         "cidr": "10.57.97.0/24"},
    {"name": "Tailscale",    "cidr": "100.64.0.0/10"},
]

# Known devices — map IP suffix or full IP to a label
KNOWN_DEVICES = {
    # Homelab LAN
    "10.57.57.1":   {"label": "Router/Gateway", "role": "router"},
    "10.57.57.251": {"label": "kubernetes-controlplane-1", "role": "k8s-node"},
    "10.57.57.252": {"label": "kubernetes-controlplane-2", "role": "k8s-node"},
    "10.57.57.253": {"label": "kubernetes-controlplane-3", "role": "k8s-node"},
    "10.57.57.254": {"label": "NAS / Management", "role": "nas"},
    # WiFi
    "10.57.97.1":   {"label": "WiFi Router", "role": "router"},
    # Tailscale peers
    "100.102.40.118": {"label": "VPS Oracle (this host)", "role": "vps"},
    "100.68.215.121": {"label": "MacBook Pro (Merox)", "role": "laptop"},
    "100.83.170.68":  {"label": "DESKTOP-9UFPTME", "role": "workstation"},
    "100.90.145.33":  {"label": "nixos", "role": "homelab"},
    "100.95.15.64":   {"label": "vps01", "role": "vps"},
    "100.99.34.94":   {"label": "fw (firewall/router)", "role": "router"},
}

now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def ping(ip):
    r = subprocess.run(['ping', '-c', '1', '-W', '1', ip],
                       capture_output=True, timeout=3)
    return r.returncode == 0

def hostname(ip):
    try:
        return socket.gethostbyaddr(ip)[0]
    except:
        return None

def gen_ips_24(base):
    return [f"{base}.{i}" for i in range(1, 255)]

def gen_tailscale_ips():
    # Only scan known Tailscale /16 ranges (100.64-127) — sample first /24
    return [f"100.{b}.{i}" for b in range(64, 128) for i in range(1, 5)][:200]

results = []
total_online = 0

for subnet_def in SUBNETS:
    cidr = subnet_def["cidr"]
    name = subnet_def["name"]
    base = '.'.join(cidr.split('.')[:3])

    if "Tailscale" in name:
        # Use `tailscale status` if available, else skip
        try:
            r = subprocess.run(['tailscale', 'status', '--json'],
                               capture_output=True, timeout=10, text=True)
            if r.returncode == 0:
                ts_data = json.loads(r.stdout)
                peers = ts_data.get('Peer', {})
                hosts = []
                for peer_key, peer in peers.items():
                    ips = peer.get('TailscaleIPs', [])
                    hostname_val = peer.get('HostName') or peer.get('DNSName', '').split('.')[0]
                    online = peer.get('Online', False)
                    if ips:
                        ip = ips[0]
                        known = KNOWN_DEVICES.get(ip, {})
                        hosts.append({
                            "ip": ip,
                            "hostname": hostname_val or None,
                            "label": known.get("label") or hostname_val or ip,
                            "role": known.get("role", peer.get('OS', 'unknown')),
                            "online": online,
                            "known": bool(known),
                        })
                online_count = sum(1 for h in hosts if h.get('online'))
                results.append({
                    "name": name,
                    "cidr": cidr,
                    "online": online_count,
                    "total_scanned": len(hosts),
                    "hosts": sorted(hosts, key=lambda x: x['ip']),
                })
                total_online += online_count
                print(f"[update-network] Tailscale: {online_count}/{len(hosts)} peers online")
                continue
        except Exception as e:
            print(f"[update-network] tailscale status failed: {e}")
        results.append({"name": name, "cidr": cidr, "online": 0, "hosts": [], "error": "tailscale not available"})
        continue

    # Standard /24 ping scan
    ips = gen_ips_24(base)
    online_hosts = []

    with ThreadPoolExecutor(max_workers=60) as ex:
        futures = {ex.submit(ping, ip): ip for ip in ips}
        for f in as_completed(futures):
            ip = futures[f]
            try:
                if f.result():
                    h = hostname(ip)
                    known = KNOWN_DEVICES.get(ip, {})
                    online_hosts.append({
                        "ip": ip,
                        "hostname": h,
                        "label": known.get("label") or h or ip,
                        "role": known.get("role", "unknown"),
                        "online": True,
                        "known": bool(known),
                    })
            except:
                pass

    online_hosts.sort(key=lambda x: list(map(int, x["ip"].split("."))))
    results.append({
        "name": name,
        "cidr": cidr,
        "online": len(online_hosts),
        "total_scanned": len(ips),
        "hosts": online_hosts,
    })
    total_online += len(online_hosts)
    print(f"[update-network] {name}: {len(online_hosts)} hosts online")

output = {
    "updatedAt": now,
    "totalOnline": total_online,
    "subnets": results,
}

with open("/srv/dashboard/data/network.json", "w") as f:
    json.dump(output, f, indent=2)

print(f"[update-network] Done — {total_online} total hosts online across {len(results)} subnets")
PYEOF
